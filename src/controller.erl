-module(controller).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

-export([find_chatroom/1]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user}).
% -record(aurora_backlog, {phone_number, message}).
% -record(aurora_messages, {userID, message, chatRoomID, timestamp}).
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
            Status = create_user(ParsedJson, Socket),
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



handle_cast({send_chat_message, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    RoomInfo = async_find_room_and_respond(ParsedJson, FromSocket),

    case RoomInfo of

        no_such_room -> error;

        _ ->
    
            UserNumbersFound = maps:get(room_users, RoomInfo),

            F = fun(UserNumber) ->
                % skip the sender's own number
                case UserNumber =/= FromPhoneNumber of 
                    true ->
                        User = find_user(UserNumber),
                        send_message(User, ParsedJson, FromSocket);
                    false -> skip
                end
            end,

            lists:foreach(F, UserNumbersFound)
    end,
    
    {noreply, State};

% update_socket shouldn't respond, even if it fails

handle_cast({update_socket, ParsedJson, SocketToUpdate}, State) ->

    update_socket(ParsedJson, SocketToUpdate),
    {noreply, State};

handle_cast({create_chatroom, ParsedJson, FromSocket}, State) ->

    Users = convert_string_list_to_binary(maps:get(users, ParsedJson)),

    ValidateResult = validate_users(Users),

    case ValidateResult of

        {ok, users_validated, UserSockets} ->
    
            DatabaseResult = create_chatroom(ParsedJson),
            case DatabaseResult of
                {ok, room_created, ChatRoomId, ChatRoomName, Users} ->

                    % no need to abtract out yet??
                    gen_tcp:send(FromSocket, jsx:encode(#{
                        <<"status">>        => 1,
                        <<"chatroom_id">>   => ChatRoomId,
                        <<"type">>          => <<"CREATE_ROOM">>
                    })),

                    % send status to all users
                    F = fun(Socket) ->
                        send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, Socket)
                    end,
                    lists:foreach(F, UserSockets);

                error ->
                    chat_server:status_reply(FromSocket, 3, <<"CREATE_ROOM">>)
            end;

        error ->

            chat_server:status_reply(FromSocket, 5, <<"CREATE_ROOM">>)
    end,

    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.


%%%%%%%%%%%%%%%%%%%%%
%%% Main functions
%%%%%%%%%%%%%%%%%%%%%

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

async_find_room_and_respond(ParsedJson, FromSocket) ->

    ChatRoomId  = maps:get(chatroom_id, ParsedJson),

    case find_chatroom(ChatRoomId) of
        #{chatroom_name := ChatRoomName, 
          room_users    := RoomUsers, 
          admin_user    := AdminUser} ->

            #{chatroom_name => ChatRoomName, 
              room_users    => RoomUsers, 
              admin_user    => AdminUser};

        _ ->

            chat_server:status_reply(FromSocket, 5),
            no_such_room

    end.

send_message(UserFound, ParsedJson, FromSocket) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    ChatRoomId      = maps:get(chatroom_id, ParsedJson),

    ToSocket = maps:get(active_socket, UserFound),

    Status = gen_tcp:send(ToSocket, 
        jsx:encode(#{
        <<"from_phone_number">> => FromPhoneNumber,
        <<"chatroom_id">>       => ChatRoomId,
        <<"message">>           => Message,
        <<"type">>              => <<"TEXT">>
        })),

    case Status of
        ok ->
            % message sent successfully
            chat_server:status_reply(FromSocket, 1, <<"TEXT">>, maps:get(phone_number, UserFound));
        _ ->
            % socket closed
            chat_server:status_reply(FromSocket, 7, <<"TEXT">>)
    end.


send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, Socket) ->

    Status = gen_tcp:send(Socket, 
        jsx:encode(#{
            <<"chatroom_id">>   => ChatRoomId,
            <<"chatroom_name">> => ChatRoomName,
            <<"users">>         => Users,
            <<"type">>          => <<"ROOM_INVITATION">>
        })).

validate_users(Users) ->
    
    F = fun(UserPhoneNumber) ->

        DatabaseResult = find_user(UserPhoneNumber),
        io:format("~p~p~n", [UserPhoneNumber, DatabaseResult]),
        case DatabaseResult of
            #{username     := _UserName, 
            session_token  := _SessionToken, 
            rooms          := _Rooms, 
            current_ip     := _IPaddress, 
            active_socket  := Socket} ->

                Socket;

            no_such_user -> no_such_user
        end
    end,

    UserSockets = lists:map(F, Users),
    io:format("validate_users debug message: ~p~n", [UserSockets]),

    case lists:member(no_such_user, UserSockets) of
        true ->
            error;
        false ->
            {ok, users_validated, UserSockets}
    end.

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

                #{phone_number => PhoneNumber,
                username       => UserName, 
                session_token  => SessionToken, 
                rooms          => Rooms, 
                current_ip     => IPaddress, 
                active_socket  => Socket};
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

update_socket(ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    {ok, {IPaddress, _Port}} = inet:peername(Socket),
    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{current_ip    = IPaddress,
                                                active_socket = Socket},
        mnesia:write(UpdatedUser)
        
    end,
    mnesia:activity(transaction, F).

create_user(ParsedJson, Socket) ->
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

% delete_user(ParsedJson) ->
%     PhoneNumber  = maps:get(from_phone_number, ParsedJson),

%     F = fun() ->
%         mnesia:delete(aurora_users, PhoneNumber)
%     end,
%     mnesia:activity(transaction, F).

create_chatroom(ParsedJson) ->

    AdminUser    = maps:get(from_phone_number, ParsedJson),
    ChatRoomName = maps:get(chatroom_name, ParsedJson),
    Users        = maps:get(users, ParsedJson),

    ChatRoomId   = list_to_binary(random_id_generator()),

    F = fun() ->
        Status = mnesia:write(#aurora_chatrooms{chatroom_id   = ChatRoomId,
                                                admin_user    = AdminUser,
                                                chatroom_name = ChatRoomName,
                                                room_users    = Users}),
        case Status of
            ok -> {ok, room_created, ChatRoomId, ChatRoomName, Users};
            _  -> error
        end

    end,
    mnesia:activity(transaction, F).

find_chatroom(ChatRoomId) ->

    F = fun() ->
        case mnesia:read({aurora_chatrooms, ChatRoomId}) of
            [#aurora_chatrooms{chatroom_name = ChatRoomName,
                               room_users    = RoomUsers,
                               admin_user    = AdminUser}] ->

                #{chatroom_id   => ChatRoomId,
                  chatroom_name => ChatRoomName,
                  room_users    => RoomUsers,
                  admin_user    => AdminUser};

            _ ->
                no_such_room
        end
    end,
    mnesia:activity(transaction, F).

% create_room(Name, RoomName) ->
    

% create_user_to_room(Name, RoomId)
% leave_room(Name, RoomId)
% delete_room(Name, RoomId) % to verify that he's indeed the admin of the room

%%%%%%%%%%%%%%%%%%%%
%%% Auxilliary functions
%%%%%%%%%%%%%%%%%%%%

random_id_generator() -> 
    <<I:160/integer>> = crypto:hash(sha,term_to_binary({make_ref(), now()})), 
    erlang:integer_to_list(I, 16).

convert_string_list_to_binary(List) ->
    F = fun(Item) ->
        case is_binary(Item) of
            true ->
                Item;
            false ->
                list_to_binary(Item)
        end
    end,
    lists:map(F, List).

% trim_whitespace(Input) ->
%    string:strip(Input, both, $\r).

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

% handle_call(Message, _From, State) ->

%     case Message of
%         {connect, Name, Socket} ->
%             case create_user(Name, Socket) of
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