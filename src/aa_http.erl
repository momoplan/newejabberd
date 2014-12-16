-module(aa_http).

-behaviour(gen_server).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").

%% API
-export([start_link/0]).

-define(Port,5384).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
		 stop/0]).

-record(state, {}).
-record(success,{success=true,entity}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
	exit(erlang:whereis(?MODULE), kill),
	spawn(fun() ->
				  timer:sleep(3000),
				  aa_http:init([])
		  end).

handle_http(Req) ->
	try
		Method = Req:get(method),
		Args = case Method of
				   'GET' ->
					   Req:parse_qs();
				   'POST' ->
					   Req:parse_post();
				   'HEAD' ->
					   []
			   end,
		if Args == [] ->
			   skip;
		   true ->			   
			   [{"body",Body}] = Args,
			   ?DEBUG("###### handle_http :::> Body=~p",[Body]),
			   {ok,Obj,_Re} = rfc4627:decode(Body),
			   %%{ok,T} = rfc4627:get_field(Obj, "token"),
			   {ok,M} = rfc4627:get_field(Obj, "method"),
			   
			   case binary_to_list(M) of 
				   "message_count" ->
					   GoodNodes = lists:filter(fun(Node) ->
														P = rpc:call(Node,erlang,whereis,[aa_msg_statistic]),
														is_pid(P)
												end, [node()|nodes()]),
					   Datas =	[begin 
									 {ok, Info} = rpc:call(Node,aa_msg_statistic,info,[]),
									 {Node, Info}
								 end || Node <- GoodNodes],
					   {ok, {Total, TotalDel, TotalToday, TotalTodayDel}} = aa_msg_statistic:info(),
					   Json = lists:map(fun({Node, {Total, TotalDel, TotalToday, TotalTodayDel}}) ->
												{obj, [{node, Node},
													   {total, Total}, 
													   {total_delete, TotalDel},
													   {today_total, TotalToday},
													   {today_total_delete, TotalTodayDel}]}
										end, Datas),
					   http_response({#success{success=true,entity=Json},Req});
				   "process_counter" ->
					   Counter = aa_process_counter:process_counter(),
					   http_response({#success{success=true,entity=Counter},Req});
				   "get_user_list" ->
					   UserList = aa_session:get_user_list(Body),	
					   http_response({#success{success=true,entity=UserList},Req});
				   "remove_group" ->
					   Params = get_group_info(Body),
					   ?DEBUG("remove_group params=~p",[Params]),
					   {ok,Gid1} = rfc4627:get_field(Params,"gid"),
					   Gid = binary_to_list(Gid1),
					   Result = aa_group_chat:remove_group(Gid),	
					   http_response({#success{success=true,entity=Result},Req});
				   "remove_user" ->
					   Params = get_group_info(Body),
					   {ok,Gid1} = rfc4627:get_field(Params,"gid"),
					   {ok,Uid1} = rfc4627:get_field(Params,"uid"),
					   Gid = binary_to_list(Gid1),
					   Uid = binary_to_list(Uid1),
					   Result = aa_group_chat:remove_user(Gid,Uid),	
					   http_response({#success{success=true,entity=Result},Req});
				   "append_user" ->
					   Params = get_group_info(Body),
					   {ok,Gid1} = rfc4627:get_field(Params,"gid"),
					   {ok,Uid1} = rfc4627:get_field(Params,"uid"),
					   Gid = binary_to_list(Gid1),
					   Uid = binary_to_list(Uid1),
					   Result = aa_group_chat:append_user(Gid,Uid),	
					   http_response({#success{success=true,entity=Result},Req});
				   "ack" ->
					   case rfc4627:get_field(Obj, "service") of
						   {ok,<<"emsg_bridge">>} ->
							   Result = aa_bridge:ack(Body),
							   http_response({#success{success=true,entity=Result},Req});
						   _ ->
							   http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
					   end;
				   "route" ->
					   case rfc4627:get_field(Obj, "service") of
						   {ok,<<"emsg_bridge">>} ->
							   Result = aa_bridge:route(Body),
							   http_response({#success{success=true,entity=Result},Req});
						   _ ->
							   http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
					   end;
				   _ ->
					   http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
			   end
		end
	catch
		C:Reason -> 
			?ERROR_MSG("aa_http c=~p ; reason=~p",[C,Reason]),
		http_response({#success{success=false,entity=list_to_binary("bad argrment")},Req})
	end.
%% 	gen_server:call(?MODULE,{handle_http,Req}).

http_response({S,Req}) ->
	Res = {obj,[{success,S#success.success},{entity,S#success.entity}]},
	?DEBUG("##### http_response ::::> S=~p",[Res]),
	J = rfc4627:encode(Res),
	?DEBUG("##### http_response ::::> J=~p",[J]),
	Req:ok([{"Content-Type", "text/json"}], "~s", [J]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
	?ERROR_MSG("aa http init []", []),
	misultin:start_link([{port, ?Port}, {loop, fun(Req) -> handle_http(Req) end}]),
	?ERROR_MSG("aa http init end", []),
	{ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% http://localhost:5380/?body={"method":"process_counter"}
%% handle_call({handle_http,Req}, _From, State) ->
%% 	Reply = try
%% 		Method = Req:get(method),
%% 		Args = case Method of
%% 			'GET' ->
%% 				Req:parse_qs();
%% 			'POST' ->
%% 				Req:parse_post()
%% 		end,
%% 		[{"body",Body}] = Args,
%% 		?DEBUG("###### handle_http :::> Body=~p",[Body]),
%% 		{ok,Obj,_Re} = rfc4627:decode(Body),
%% 		%%{ok,T} = rfc4627:get_field(Obj, "token"),
%% 		{ok,M} = rfc4627:get_field(Obj, "method"),
%% 
%% 		case binary_to_list(M) of 
%% 			"process_counter" ->
%% 				Counter = aa_process_counter:process_counter(),
%% 				http_response({#success{success=true,entity=Counter},Req});
%% 			"get_user_list" ->
%% 				UserList = aa_session:get_user_list(Body),	
%% 				http_response({#success{success=true,entity=UserList},Req});
%% 			"remove_group" ->
%% 				Result = aa_group_chat:remove_group(Body),	
%% 				http_response({#success{success=true,entity=Result},Req});
%% 			"remove_user" ->
%% 				Result = aa_group_chat:remove_user(Body),	
%% 				http_response({#success{success=true,entity=Result},Req});
%% 			"append_user" ->
%% 				Result = aa_group_chat:append_user(Body),	
%% 				http_response({#success{success=true,entity=Result},Req});
%% 			"ack" ->
%% 				case rfc4627:get_field(Obj, "service") of
%% 					{ok,<<"emsg_bridge">>} ->
%% 						Result = aa_bridge:ack(Body),
%% 						http_response({#success{success=true,entity=Result},Req});
%% 					_ ->
%% 						http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
%% 				end;
%% 			"route" ->
%% 				case rfc4627:get_field(Obj, "service") of
%% 					{ok,<<"emsg_bridge">>} ->
%% 						Result = aa_bridge:route(Body),
%% 						http_response({#success{success=true,entity=Result},Req});
%% 					_ ->
%% 						http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
%% 				end;
%% 			_ ->
%% 				http_response({#success{success=false,entity=list_to_binary("method undifine")},Req})
%% 		end
%% 	catch
%% 		C:Reason -> 
%% 			?INFO_MSG("aa_http c=~p ; reason=~p",[C,Reason])
%% 	end,
%% 	{reply,Reply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
handle_cast(_Msg, State) ->
    {noreply, State}.
handle_info(_Info, State) ->
    {noreply, State}.
terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


get_group_info(Body) ->
	{ok,Obj,_Re} = rfc4627:decode(Body),
	{ok,Params} = rfc4627:get_field(Obj,"params"),
	Params.
