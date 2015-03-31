-module(controller).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
% -record(aurora_messages, {userID, message, chatRoomID, timestamp}).
% -record(aurora_chatrooms, {chatRoomID, roomUsers, adminUser}).
% -record(aurora_notes, {userID, message}).


start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% This is called when a connection is made to the server
init([]) ->
    State = [],
    {ok, State}.

handle_call({register, ParsedJson, Socket}, _From, State) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    % UserName     = maps:get(username, jsx:decode(Data, [{labels, atom}, return_maps])),
    % SessionToken = maps:get(session_token, jsx:decode(Data, [{labels, atom}, return_maps])),

    case user_exists(PhoneNumber) of

        user_exists ->
            
            Status = update_user(ParsedJson, Socket),
            case Status of
                % return value from update_user mnesia database transaction
                ok ->
                    {reply, ok, State};
                _ ->
                    {reply, error, State}
            end;

        no_such_user ->
            Status = add_user(ParsedJson, Socket),
            case Status of
                ok ->
                    {reply, ok, State};
                _ ->
                    {reply, error, State}
            end
    end;

handle_call({authorize_request, ParsedJson}, _From, State) ->

    TokenToCheck = maps:get(session_token, ParsedJson),
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    case find_user(PhoneNumber) of
        #{username     := _UserName, 
        session_token  := SessionToken, 
        rooms          := _Rooms, 
        current_ip     := _IPaddress, 
        active_socket  := _Socket} ->

            case SessionToken == TokenToCheck of
                true ->
                    {reply, authorized, State};
                false ->
                    {reply, error, State}

            end;

        _ ->
            {reply, no_such_user, State}

    end.

async_find_user_and_respond(ParsedJson, FromSocket) ->

    PhoneNumber  = maps:get(to_phone_number, ParsedJson),

    case find_user(PhoneNumber) of
        #{username     := UserName, 
        session_token  := SessionToken, 
        rooms          := Rooms, 
        current_ip     := IPaddress, 
        active_socket  := Socket} ->

            #{username      => UserName, 
              session_token => SessionToken, 
              rooms         => Rooms, 
              current_ip    => IPaddress, 
              active_socket => Socket};

        _ ->

        chat_server:status_reply(FromSocket, 5),
        no_such_user

    end.

send_message(UserFound, ParsedJson, FromSocket) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),

    ToSocket = maps:get(active_socket, UserFound),

    Status = gen_tcp:send(ToSocket, 
        jsx:encode(#{
        <<"from_phone_number">> => FromPhoneNumber,
        <<"chatroom_id">>       => ChatRoomID,
        <<"message">>           => Message,
        <<"type">>              => <<"TEXT">>
        })),

    case Status of
        ok ->
            % message sent successfully
            chat_server:status_reply(FromSocket, 1);
        _ ->
            % socket closed
            chat_server:status_reply(FromSocket, 7)
    end.


handle_cast({send_chat_message, ParsedJson, FromSocket}, State) ->
    
    UserFound = async_find_user_and_respond(ParsedJson, FromSocket),

    if 
        UserFound =/= no_such_user ->

            send_message(UserFound, ParsedJson, FromSocket);

        true -> error

    end,

    
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%
%%% Mnesia interface
%%%%%%%%%%%%%%%%%%%%

user_exists(PhoneNumber) ->
    F = fun() ->
        case mnesia:read({aurora_users, PhoneNumber}) of
            [#aurora_users{}] ->
                user_exists;
            _ ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

find_user(PhoneNumber) ->
    F = fun() ->
        case mnesia:read({aurora_users, PhoneNumber}) of
            [#aurora_users{username      = UserName, 
                           session_token = SessionToken,
                           rooms         = Rooms,
                           current_ip    = IPaddress,
                           active_socket = Socket}] ->

                #{username    => UserName, 
                session_token => SessionToken, 
                rooms         => Rooms, 
                current_ip    => IPaddress, 
                active_socket => Socket};
            % [H|_T] ->
            %     H;
            _ ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

update_user(ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),

    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{username      = UserName, 
                                                session_token = SessionToken,
                                                current_ip    = IPaddress,
                                                active_socket = Socket},
        mnesia:write(UpdatedUser)
        
    end,
    mnesia:activity(transaction, F).

% -record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).

add_user(ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),

    F = fun() ->
        mnesia:write(#aurora_users{phone_number = PhoneNumber, 
                                   username = UserName, 
                                   session_token = SessionToken,
                                   current_ip = IPaddress, 
                                   active_socket = Socket})
    end,
    mnesia:activity(transaction, F).

% delete_user(Name) ->
%     F = fun() ->
%         mnesia:delete(aurora_users, Name)
%     end,
%     mnesia:activity(transaction, F).

% create_room(Name, RoomName) ->
    

% add_user_to_room(Name, RoomId)
% leave_room(Name, RoomId)
% delete_room(Name, RoomId) % to verify that he's indeed the admin of the room

%%%%%%%%%%%%%%%%%%%%
%%% Auxilliary functions
%%%%%%%%%%%%%%%%%%%%

% trim_whitespace(Input) ->
%    string:strip(Input, both, $\r).

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

% handle_call(Message, _From, State) ->

%     case Message of
%         {connect, Name, Socket} ->
%             case add_user(Name, Socket) of
%                 ok ->
%                     {reply, ok, State};
%                 _ ->
%                     {reply, error, State}
%             end;

%         {disconnect, Name} ->
%             {reply, ok, State};

%         _ ->
%             {reply, error, State}

%     end.

% handle_cast({talk, OwnName, Socket, NameToFind, Message}, State) ->
%     case find_user(NameToFind) of
%         {PeerName, _Location, PeerSocket} ->
%             % FlattenLocation = lists:flatten(io_lib:format("~p", [Location])),
%             Response = gen_tcp:send(PeerSocket, OwnName ++ ": " ++ Message ++ "\n"),
%             case Response of
%                 ok ->
%                     gen_tcp:send(Socket, "Message received by: " ++ NameToFind ++ "\n");
%                 {error, _} ->
%                     gen_tcp:send(Socket, "Could not send message because " ++ PeerName ++ " is offline.\n")
%             end;
%         no_such_user ->
%             gen_tcp:send(Socket, "USER_NOT_FOUND: " ++ NameToFind)
%     end,
%     {noreply, State};