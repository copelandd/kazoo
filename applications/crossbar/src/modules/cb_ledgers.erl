%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2018, 2600Hz
%%% @doc
%%% @author Peter Defebvre
%%% @author Luis Azedo
%%% @end
%%%-----------------------------------------------------------------------------
-module(cb_ledgers).

-export([init/0
        ,allowed_methods/0, allowed_methods/1, allowed_methods/2
        ,resource_exists/0, resource_exists/1, resource_exists/2
        ,authorize/2
        ,validate/1, validate/2, validate/3
        ,put/2
        ]).

-include("crossbar.hrl").

-define(AVAILABLE, <<"available">>).
-define(CREDIT, <<"credit">>).
-define(DEBIT, <<"debit">>).

-define(VIEW_BY_TIMESTAMP, <<"ledgers/list_by_timestamp">>).
-define(VIEW_BY_SOURCE, <<"ledgers/list_by_source">>).

-define(NOTIFY_MSG, "failed to impact reseller ~s ledger : ~p").

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the bindings this module will respond to.
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = crossbar_bindings:bind(<<"*.allowed_methods.ledgers">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"*.resource_exists.ledgers">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"*.authorize.ledgers">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"*.validate.ledgers">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"*.execute.get.ledgers">>, ?MODULE, 'get'),
    _ = crossbar_bindings:bind(<<"*.execute.put.ledgers">>, ?MODULE, 'put').

%%------------------------------------------------------------------------------
%% @doc Given the path tokens related to this module, what HTTP methods are
%% going to be responded to.
%% @end
%%------------------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
allowed_methods() ->
    [?HTTP_GET].

-spec allowed_methods(path_token()) -> http_methods().
allowed_methods(?AVAILABLE) ->
    [?HTTP_GET];
allowed_methods(?CREDIT) ->
    [?HTTP_PUT];
allowed_methods(?DEBIT) ->
    [?HTTP_PUT];
allowed_methods(_SourceService) ->
    [?HTTP_GET].

-spec allowed_methods(path_token(), path_token()) -> http_methods().
allowed_methods(_SourceService, _LedgerId) ->
    [?HTTP_GET].

%%------------------------------------------------------------------------------
%% @doc Does the path point to a valid resource.
%% For example:
%%
%% ```
%%    /ledgers => []
%%    /ledgers/foo => [<<"foo">>]
%%    /ledgers/foo/bar => [<<"foo">>, <<"bar">>]
%% '''
%% @end
%%------------------------------------------------------------------------------
-spec resource_exists() -> 'true'.
resource_exists() -> 'true'.

-spec resource_exists(path_token()) -> 'true'.
resource_exists(_) -> 'true'.

-spec resource_exists(path_token(), path_token()) -> 'true'.
resource_exists(_, _) -> 'true'.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec authorize(cb_context:context(), path_token()) -> boolean() | {'stop', cb_context:context()}.
authorize(Context, Path) ->
    authorize_request(Context, Path, cb_context:req_verb(Context)).

-spec authorize_request(cb_context:context(), path_token(), http_method()) ->
                               boolean() |
                               {'stop', cb_context:context()}.
authorize_request(Context, ?DEBIT, ?HTTP_PUT) ->
    authorize_create(Context);
authorize_request(Context, ?CREDIT, ?HTTP_PUT) ->
    authorize_create(Context);
authorize_request(Context, _, ?HTTP_PUT) ->
    {'stop', cb_context:add_system_error('forbidden', Context)}.

-spec authorize_create(cb_context:context()) -> boolean() |
                                                {'stop', cb_context:context()}.
authorize_create(Context) ->
    IsAuthenticated = cb_context:is_authenticated(Context),
    IsSuperDuperAdmin = cb_context:is_superduper_admin(Context),
    ResellerId = cb_context:reseller_id(Context),
    AuthAccountId = cb_context:auth_account_id(Context),
    IsReseller = kz_term:is_not_empty(AuthAccountId)
        andalso ResellerId =:= AuthAccountId,
    case IsAuthenticated
        andalso (IsSuperDuperAdmin
                 orelse IsReseller
                )
    of
        'true' -> 'true';
        'false' -> {'stop', cb_context:add_system_error('forbidden', Context)}
    end.

%%------------------------------------------------------------------------------
%% @doc Check the request (request body, query string params, path tokens, etc)
%% and load necessary information.
%% /ledgers might load a list of ledgers objects
%% /ledgers/123 might load the ledgers object 123
%% Generally, use crossbar_doc to manipulate the cb_context{} record
%% @end
%%------------------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
validate(Context) ->
    Options = [{'group', 'true'}
              ,{'group_level', 0}
              ,{'mapper', crossbar_view:map_value_fun()}
              ,{'reduce', 'true'}
              ,{'unchunkable', 'true'}
              ],
    Context1 = crossbar_view:load_modb(Context, ?VIEW_BY_TIMESTAMP, Options),
    case cb_context:resp_status(Context1) of
        'success' ->
            Summary = kz_json:sum_jobjs(cb_context:doc(Context1)),
            cb_context:set_resp_data(Context1, summary_to_dollars(Summary));
        _ ->
            Context1
    end.

-spec validate(cb_context:context(), path_token()) -> cb_context:context().
validate(Context, ?CREDIT) ->
    cb_context:validate_request_data(<<"ledgers">>, Context);
validate(Context, ?DEBIT) ->
    cb_context:validate_request_data(<<"ledgers">>, Context);
validate(Context, ?AVAILABLE) ->
    Available = kz_ledgers:available_ledgers(cb_context:account_id(Context)),
    Setters = [{fun cb_context:set_resp_status/2, 'success'}
              ,{fun cb_context:set_resp_data/2, Available}
              ],
    cb_context:setters(Context, Setters);
validate(Context, SourceService) ->
    ViewOptions = [{'is_chunked', 'true'}
                  ,{'range_keymap', SourceService}
                  ,{'mapper', fun normalize_view_results/3}
                  ,'include_docs'
                  ],
    crossbar_view:load_modb(Context, ?VIEW_BY_SOURCE, ViewOptions).

-spec validate(cb_context:context(), path_token(), path_token()) -> cb_context:context().
validate(Context, SourceService, Id) ->
    AccountId = cb_context:account_id(Context),
    case kz_ledger:fetch(AccountId, Id) of
        {'ok', Ledger} ->
            validate_fetch_ledger(Context, SourceService, Ledger);
        {'error', Reason} ->
            crossbar_doc:handle_datamgr_errors(Reason, Id, Context)
    end.

-spec validate_fetch_ledger(cb_context:context(), kz_term:ne_binary(), kz_ledger:ledger()) ->
                                   cb_context:context().
validate_fetch_ledger(Context, SourceService, Ledger) ->
    case kz_ledger:source_service(Ledger) =:= SourceService of
        'true' ->
            Setters = [{fun cb_context:set_resp_status/2, 'success'}
                      ,{fun cb_context:set_resp_data/2, kz_ledger:public_json(Ledger)}
                      ],
            cb_context:setters(Context, Setters);
        'false' ->
            Id = kz_ledger:id(Ledger),
            Error = kz_json:from_list([{<<"cause">>, Id}]),
            cb_context:add_system_error('bad_identifier', Error,  Context)
    end.

%%------------------------------------------------------------------------------
%% @doc If the HTTP verb is POST, execute the actual action, usually a db save
%% (after a merge perhaps).
%% @end
%%------------------------------------------------------------------------------
-spec put(cb_context:context(), path_token()) -> cb_context:context().
put(Context, Action) ->
    ReqData = cb_context:req_data(Context),
    AccountId = cb_context:account_id(Context),
    Setters =
        props:filter_empty(
          [{fun kz_ledger:set_account/2, AccountId}
          ,{fun kz_ledger:set_source_service/2
           ,kz_json:get_ne_binary_value([<<"source">>, <<"service">>], ReqData)
           }
          ,{fun kz_ledger:set_source_id/2
           ,kz_json:get_ne_binary_value([<<"source">>, <<"id">>], ReqData)
           }
          ,{fun kz_ledger:set_description/2
           ,kz_json:get_ne_binary_value(<<"description">>, ReqData)
           }
          ,{fun kz_ledger:set_usage_type/2
           ,kz_json:get_ne_binary_value([<<"usage">>, <<"type">>], ReqData)
           }
          ,{fun kz_ledger:set_usage_quantity/2
           ,kz_json:get_integer_value([<<"usage">>, <<"quantity">>], ReqData)
           }
          ,{fun kz_ledger:set_usage_unit/2
           ,kz_json:get_ne_binary_value([<<"usage">>, <<"unit">>], ReqData)
           }
          ,{fun kz_ledger:set_period_start/2
           ,kz_json:get_integer_value([<<"period">>, <<"start">>], ReqData)
           }
          ,{fun kz_ledger:set_period_end/2
           ,kz_json:get_integer_value([<<"period">>, <<"end">>], ReqData)
           }
          ,{fun kz_ledger:set_metadata/2
           ,kz_json:get_ne_json_value(<<"metadata">>, ReqData, kz_json:new())
           }
          ,{fun kz_ledger:set_dollar_amount/2
           ,abs(kz_json:get_integer_value(<<"amount">>, ReqData, 0))
           }
          ,{fun kz_ledger:set_audit/2
           ,crossbar_services:audit_log(Context)
           }
          ,{fun kz_ledger:set_executor_trigger/2
           ,<<"crossbar">>
           }
          ,{fun kz_ledger:set_executor_module/2
           ,kz_term:to_binary(?MODULE)
           }
          ]
         ),
    process_action(Context, Action, kz_ledger:setters(Setters)).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec summary_to_dollars(kz_json:object()) -> kz_json:object().
summary_to_dollars(Summary) ->
    kz_json:expand(
      kz_json:from_list(
        [{Path, maybe_convert_units(lists:last(Path), Value)}
         || {Path, Value} <- kz_json:to_proplist(kz_json:flatten(Summary))
        ])).

-spec maybe_convert_units(kz_term:ne_binary(), kz_currency:units() | T) ->
                                 kz_currency:dollars() | T when T::any().
maybe_convert_units(<<"amount">>, Units) when is_integer(Units) ->
    kz_currency:units_to_dollars(Units);
maybe_convert_units(_, Value) -> Value.

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec process_action(cb_context:context(), kz_term:ne_binary(), kz_ledger:ledger()) -> cb_context:context().
process_action(Context, ?CREDIT, Ledger) ->
    case kz_ledger:credit(Ledger) of
        {'error', Reason} ->
            crossbar_util:response('error', Reason, Context);
        {'ok', SavedLedger} ->
            maybe_impact_reseller(Context, SavedLedger)
    end;
process_action(Context, ?DEBIT, Ledger) ->
    case kz_ledger:debit(Ledger) of
        {'error', Reason} ->
            crossbar_util:response('error', Reason, Context);
        {'ok', SavedLedger} ->
            maybe_impact_reseller(Context, SavedLedger)
    end.

-spec maybe_impact_reseller(cb_context:context(), kz_ledger:ledger()) -> cb_context:context().
maybe_impact_reseller(Context, Ledger) ->
    ResellerId = cb_context:reseller_id(Context),
    ImpactReseller = kz_json:is_true(<<"impact_reseller">>, cb_context:req_json(Context))
        andalso ResellerId =/= cb_context:account_id(Context),
    maybe_impact_reseller(Context, Ledger, ImpactReseller, ResellerId).

-spec maybe_impact_reseller(cb_context:context(), kz_ledger:ledger(), boolean(), kz_term:api_binary()) -> cb_context:context().
maybe_impact_reseller(Context, Ledger, 'false', _ResellerId) ->
    crossbar_util:response(kz_ledger:public_json(Ledger), Context);
maybe_impact_reseller(Context, Ledger, 'true', 'undefined') ->
    JObj = kz_json:from_list(
             [{kz_ledger:account_id(Ledger)
              ,kz_ledger:public_json(Ledger)
              }
             ]
            ),
    crossbar_util:response(JObj, Context);
maybe_impact_reseller(Context, AccountLedger, 'true', ResellerId) ->
    AccountId = kz_ledger:account_id(AccountLedger),
    AccountResponse = build_success_response(AccountId, AccountLedger),
    case kz_ledger:save(kz_ledger:reset(AccountLedger), ResellerId) of
        {'ok', ResellerLedger} ->
            ResellerResponse = build_success_response(ResellerId, ResellerLedger),
            JObj = build_response(AccountId, AccountResponse
                                 ,ResellerId, ResellerResponse
                                 ),
            crossbar_util:response(JObj, Context);
        {'error', Reason} ->
            ResellerResponse = build_error_response(Context, AccountId, Reason),
            JObj = build_response(AccountId, AccountResponse
                                 ,ResellerId, ResellerResponse
                                 ),
            crossbar_util:response(JObj, Context)
    end.

-spec build_response(kz_term:ne_binary(), kz_json:object()
                    ,kz_term:ne_binary(), kz_json:object()) ->
                            kz_json:object().
build_response(AccountId, AccountResponse, ResellerId, ResellerResponse) ->
    kz_json:from_list(
      [{AccountId, AccountResponse},
       {ResellerId, ResellerResponse}
      ]
     ).

-spec build_error_response(cb_context:context(), kz_term:ne_binary(), any()) -> kz_json:object().
build_error_response(Context, AccountId, Reason) ->
    Context1 = crossbar_doc:handle_datamgr_errors(Reason, 'undefined', Context),
    kz_json:from_list(
      [{<<"error">>, cb_context:resp_data(Context1)}
      ,{<<"available_dollars">>, kz_currency:available_dollars(AccountId, 0)}
      ,{<<"is_reseller">>, kz_services_reseller:is_reseller(AccountId)}
      ]
     ).

-spec build_success_response(kz_term:ne_binary(), kz_ledger:ledger()) -> kz_json:object().
build_success_response(AccountId, Ledger) ->
    kz_json:from_list(
      [{<<"ledger">>, kz_ledger:public_json(Ledger)}
      ,{<<"available_dollars">>, kz_currency:available_dollars(AccountId, 0)}
      ,{<<"is_reseller">>, kz_services_reseller:is_reseller(AccountId)}
      ]
     ).

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec normalize_view_results(cb_context:context(), kzd_ledgers:doc(), kz_json:objects()) ->
                                    kz_json:objects().
normalize_view_results(_Context, JObj, Acc) ->
    [normalize_view_result(kz_json:get_value(<<"doc">>, JObj)) | Acc].

-spec normalize_view_result(kzd_ledgers:doc()) -> kz_json:object().
normalize_view_result(LedgerJObj) ->
    kz_ledger:public_json(kz_ledger:from_json(LedgerJObj)).
