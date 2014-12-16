-module(aa_group_chat).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("aa_data.hrl").
-include("logger.hrl").

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(HTTP_HEAD,"application/x-www-form-urlencoded").

%% ====================================================================
%% API functions
%% ====================================================================
-export([
	start_link/0,
	route_group_msg/3,
	is_group_chat/1,
	append_user/2,
	remove_user/2,
	remove_group/1,
	reload_group_members/0
%% 	reload_group_members_local/0
]).

-record(state, { ecache_node, ecache_mod=ecache_server, ecache_fun=cmd }).

start() ->
	aa_group_chat_sup:start_child().


start_link() ->
	gen_server:start_link(?MODULE,[],[]).


%% reload_group_members() ->
%% 	[reload_group_members(Node) || Node <- [node()|nodes()]].
%% 
%% reload_group_members(Node) ->
%% 	spawn(fun() ->
%% 				  rpc:call(Node, aa_group_chat, reload_group_members_local, [])
%% 		  end).

reload_group_members() ->
	GroupIds = mnesia:dirty_all_keys(?GOUPR_MEMBER_TABLE),
	[Domain|_] = ?MYHOSTS, 
	F = fun(GroupId) ->
			case get_user_list_by_group_id(Domain,GroupId) of 
				{ok,UserList} ->
					Data = #group_members{gid = GroupId, members = UserList},
					mnesia:dirty_write(?GOUPR_MEMBER_TABLE, Data),
					?DEBUG("###### get_user_list_by_group_id_http :::> GroupId=~p ; Roster=~p",[GroupId,UserList]),
					{ok,UserList};
				Err ->
					?ERROR_MSG("ERROR=~p",[Err]),
					mnesia:dirty_delete(?GOUPR_MEMBER_TABLE, GroupId),
					error
			end
	end,
	lists:foreach(F, GroupIds).

route_group_msg(From,GroupId,Packet)->
	{ok,Pid} = start(),
	?DEBUG("###### route_group_msg_001 ::::> {From,To,Packet}=~p",[{From,GroupId,Packet}]),
	gen_server:cast(Pid,{route_group_msg,From,GroupId,Packet}).

%% {"service":"group_chat","method":"remove_user","params":{"domain":"test.com","gid":"123123","uid":"123123"}}
%% "{\"method\":\"remove_user\",\"params\":{\"domain\":\"test.com\",\"gid\":\"123123\",\"uid\":\"123123\"}}"
append_user(Gid,Uid)->
	case mnesia:dirty_read(?GOUPR_MEMBER_TABLE, Gid) of
		[] ->
			skip;
		[#group_members{members = Members}] ->
			case lists:member(Uid, Members) of
				true ->
					skip;
				false ->					
					NewMembers = [Uid|Members],
					mnesia:dirty_write(?GOUPR_MEMBER_TABLE, #group_members{gid = Gid, members = NewMembers})
			end;
		_ ->
			skip
	end,
	ok.
remove_user(Gid,Uid)->
	?DEBUG("remove user ~p from ~p", [Uid, Gid]),
	case mnesia:dirty_read(?GOUPR_MEMBER_TABLE, Gid) of
		[] ->
			skip;
		[#group_members{members = Members}] ->
			NewMembers = lists:delete(Uid, Members),
			?DEBUG("remove sucess", []),
			mnesia:dirty_write(?GOUPR_MEMBER_TABLE, #group_members{gid = Gid, members = NewMembers});
		_ ->
			skip
	end,
	?DEBUG("remove over", []),
	ok.
remove_group(Gid)->
	mnesia:dirty_delete(?GOUPR_MEMBER_TABLE, Gid),
	ok.

%% ====================================================================
%% Behavioural functions 
%% ====================================================================
init([]) ->
	{ok, #state{}}.

handle_call(_Requset,_From, State) ->
	{reply,ok,State}.

handle_cast({route_group_msg,#jid{server=Domain,user=FU}=From,GroupId,Packet}, State) ->
	Result =
		case mnesia:dirty_read(?GOUPR_MEMBER_TABLE, GroupId) of
			[] ->
				case get_user_list_by_group_id(Domain,GroupId) of 
					{ok,UserList} ->
						Data = #group_members{gid = GroupId, members = UserList},
						mnesia:dirty_write(?GOUPR_MEMBER_TABLE, Data),
%% 						?WARNING_MSG("###### get_user_list_by_group_id_http :::> GroupId=~p ; Roster=~p",[GroupId,UserList]),
						{ok,UserList};
					Err ->
						?ERROR_MSG("ERROR=~p",[Err]),
						error
				end;
			[#group_members{members = Members}] ->
				{ok,Members};
			
			_ ->
				error
		end,
	case Result of
		{ok,Res} ->
%% 			?WARNING_MSG("###### begin send group msg :::> GroupId=~p ; member=~p",[GroupId,Res]),
			case lists:member(FU,Res) of
				true->
					%% -record(jid, {user, server, resource, luser, lserver, lresource}).
					Roster = [begin 
								  case is_list(User) of
									  true ->
										  UID = list_to_binary(User);
									  false ->
										  UID = User
								  end,
								  if FU == UID ->
										 skip;
									 true ->
										 #jid{user=UID,server=Domain,luser=UID,lserver=Domain,resource=[],lresource=[]}
								  end
							  end || User <- Res],
					?DEBUG("###### route_group_msg 002 :::> GroupId=~p ; Roster=~p",[GroupId,Roster]),
					lists:foreach(fun(skip) ->
										  skip;
									 (Target) ->
										  spawn(fun()-> route_msg(From,Target,Packet,GroupId) end)
								  end,Roster);
				_ ->
					?ERROR_MSG("from_user_not_in_group id=~p ; from_user=~p",[GroupId,FU]), 
					error
			end;
		_ ->
			error
	end,
	{stop, normal, State};
handle_cast(stop, State) ->
	{stop, normal, State}.

handle_info(_Info, State) ->
    {noreply, State}.


%% terminate/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:terminate-2">gen_server:terminate/2</a>
-spec terminate(Reason, State :: term()) -> Any :: term() when
	Reason :: normal
			| shutdown
			| {shutdown, term()}
			| term().
%% ====================================================================
terminate(_Reason, _State) ->
    ok.


%% code_change/3
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:code_change-3">gen_server:code_change/3</a>
-spec code_change(OldVsn, State :: term(), Extra :: term()) -> Result when
	Result :: {ok, NewState :: term()} | {error, Reason :: term()},
	OldVsn :: Vsn | {down, Vsn},
	Vsn :: term().
%% ====================================================================
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
%% ====================================================================
%% Internal functions
%% ====================================================================
get_user_list_by_group_id(Domain,GroupId)->
	?DEBUG("###### get_user_list_by_group_id :::> GroupId=~p",[GroupId]),
	HTTPServer =  ejabberd_config:get_local_option({http_server,Domain},
                                       fun(V) -> V end),
	%% 取自配置文件 ejabberd.cfg
	HTTPService = ejabberd_config:get_local_option({http_server_service_client,Domain},
                                       fun(V) -> V end),
	HTTPTarget = binary_to_list(<<HTTPServer/binary, HTTPService/binary>>),

	{Service,Method,GID,SN} = {
			<<"service.groupchat">>,
			<<"getUserList">>,
			GroupId,
			list_to_binary(aa_hookhandler:get_id())
	},
	Form = <<"body=\"{\"sn\":\"",SN,"\",\"service\":\"",Service,"\",\"method\":\"",Method,"\",\"params\":{\"groupId\":\"",GID,"\"}}\"">>,
	?DEBUG("###### get_user_list_by_group_id :::> HTTP_TARGET=~p ; request=~p",[HTTPTarget,Form]),
	try
		case httpc:request(post,{ HTTPTarget ,[], ?HTTP_HEAD , Form },[],[] ) of   
	        	{ok, {_,_,Body}} ->
				DBody = rfc4627:decode(Body),
				{_,Log,_} = DBody,
				?DEBUG("###### get_user_list_by_group_id :::> response=~s",[Log]),
	 			case DBody of
	 				{ok,Obj,_Re} -> 
						case rfc4627:get_field(Obj,"success") of
							{ok,true} ->
								{ok,Entity} = rfc4627:get_field(Obj,"entity"),
								?DEBUG("###### get_user_list_by_group_id :::> entity=~p",[Entity]),
								{ok,Entity};
							_ ->
								{ok,Entity} = rfc4627:get_field(Obj,"entity"),
								{fail,Entity}
						end;
	 				Error -> 
						{error,Error}
	 			end ;
	        	{error, Reason} ->
	 			?INFO_MSG("[ ERROR ] cause ~p~n",[Reason]),
				{error,Reason}
		end
	catch
		_:_->
			%% TODO 测试时，可以先固定组内成员
			{ok,[<<"e1">>,<<"e2">>,<<"e3">>]}
	end.

route_msg(#jid{user=FromUser}=From,#jid{user=User,server=Domain}=To,Packet,GroupId) ->
	case FromUser=/=User of
		true->
			{X,E,Attr,Body} = Packet,
			ID = aa_hookhandler:get_id(),
			?DEBUG("##### route_group_msg_003 param :::> {User,Domain,GroupId}=~p",[{User,Domain,GroupId}]),
			RAttr0 = lists:map(fun({K,V})-> 
				case K of 
					<<"to">> -> {<<K>>,<<User/binary, <<"@">>/binary,Domain/binary>>}; 
					"id" -> {K,list_to_binary(ID)};	
					"msgtype" -> {K,<<"groupchat">>};	
					_-> {K,V} 
				end 
			end,Attr),
			RAttr1 = lists:append(RAttr0,[{<<"groupid">>,GroupId}]),
			RAttr2 = lists:append(RAttr1,[{<<"g">>,<<"0">>}]),
			RPacket = {X,E,RAttr2,Body},
			aa_hookhandler:send_message_to_user(From, To, RPacket),
			case ejabberd_router:route(From, To, RPacket) of
				ok ->
					{ok,ok};
				Err ->
					?ERROR_MSG("###### route_group_msg 003 ERR=~p :::> {From,To,RPacket}=~p",[Err,{From,To,RPacket}]),
					{error,Err}
			end;
		_ ->
			{ok,skip}
	end.

is_group_chat(#jid{server=Domain}=To)->
	DomainTokens = string:tokens(binary_to_list(Domain),"."),
	Rtn = case length(DomainTokens) > 2 of 
		true ->
			[G|_] = DomainTokens,
			G=:="group";
		_ ->
			false
	end,
	?DEBUG("##### is_group_chat ::::>To~p ; Rtn=~p",[To,Rtn]),
	Rtn.

