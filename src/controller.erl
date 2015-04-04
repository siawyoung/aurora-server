-module(controller).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, room_users, admin_user}).
-record(aurora_message_backlog, {phone_number, messages}).
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
                    send_backlog(ParsedJson, Socket),
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
                        send_chat_message(User, ParsedJson, FromSocket);
                    false -> skip
                end
            end,

            lists:foreach(F, UserNumbersFound)
    end,
    
    {noreply, State};

% update_socket shouldn't respond, even if it fails

handle_cast({update_socket, ParsedJson, SocketToUpdate}, State) ->

    update_socket(ParsedJson, SocketToUpdate),
    send_backlog(ParsedJson, SocketToUpdate),
    {noreply, State};

handle_cast({create_chatroom, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    RawUsers = handle_list(maps:get(users, ParsedJson)),

    ValidateResult = validate_users(RawUsers),

    case ValidateResult of

        {ok, users_validated, UserInfo} ->
    
            DatabaseResult = create_chatroom(ParsedJson),
            case DatabaseResult of
                {ok, room_created, ChatRoomId, ChatRoomName, Users} ->

                    % no need to abtract out yet??
                    send_client_message(FromSocket, FromPhoneNumber, 
                    jsx:encode(#{
                        <<"status">>        => 1,
                        <<"chatroom_id">>   => ChatRoomId,
                        <<"type">>          => <<"CREATE_ROOM">>
                    })),

                    % send status to all users
                    F = fun(User) ->
                        send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, maps:get(active_socket, User), maps:get(phone_number, User))
                    end,
                    lists:foreach(F, UserInfo);

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
        #{
          chatroom_name := ChatRoomName, 
          room_users    := RoomUsers, 
          admin_user    := AdminUser} ->

            #{chatroom_name => ChatRoomName, 
              room_users    => RoomUsers, 
              admin_user    => AdminUser};

        _ ->

            chat_server:status_reply(FromSocket, 5),
            no_such_room

    end.

send_chat_message(UserFound, ParsedJson, FromSocket) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    ChatRoomId      = maps:get(chatroom_id, ParsedJson),

    ToSocket      = maps:get(active_socket, UserFound),
    ToPhoneNumber = maps:get(phone_number, UserFound),

    Status = send_client_message(ToSocket, ToPhoneNumber,
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
        error ->
            % socket closed
            chat_server:status_reply(FromSocket, 7, <<"TEXT">>)
    end.


send_chatroom_invitation(ChatRoomId, ChatRoomName, Users, Socket, PhoneNumber) ->

    send_client_message(Socket, PhoneNumber,
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

                #{phone_number  => UserPhoneNumber,
                  active_socket => Socket};

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

send_backlog(ParsedJson, Socket) ->

    PhoneNumber = maps:get(from_phone_number, ParsedJson),
    io:format("Sending backlog messages..~n",[]),
    LeftoverMessages = [],

    case find_backlog(PhoneNumber) of

        undefined ->
            io:format("There are no backlog messages.~n",[]),
            no_backlog_messages;

        no_such_user ->
            error;

        [] ->
            io:format("There are no backlog messages.~n",[]),
            no_backlog_messages;

        Messages ->

            F = fun(Message) ->
                io:format("Backlog message:~n~p~n",[Message]),
                Status = gen_tcp:send(Socket, Message),

                case Status of
                    ok ->
                        great;
                    _  ->
                        lists:append(LeftoverMessages, [Message])
                end

            end,

            lists:foreach(F, [Messages]),
            update_backlog(PhoneNumber, LeftoverMessages)


    end.

send_client_message(Socket, PhoneNumber, Message) ->
    Status = gen_tcp:send(Socket, Message),
    case Status of
        ok -> ok;
        _  -> 
            append_backlog(PhoneNumber, Message),
            error
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
                                   active_socket = Socket}),
        mnesia:write(#aurora_message_backlog{phone_number = PhoneNumber})
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

find_backlog(PhoneNumber) ->
    
    F = fun() ->
        case mnesia:read({aurora_message_backlog, PhoneNumber}) of
            [#aurora_message_backlog{messages = Messages}] ->
                Messages;
            [] ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

update_backlog(PhoneNumber, Messages) ->

    F = fun() ->

        [ExistingUser] = mnesia:wread({aurora_message_backlog, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_message_backlog{messages = Messages},
        mnesia:write(UpdatedUser)

    end,
    mnesia:activity(transaction, F).

append_backlog(PhoneNumber, Message) ->

    Backlog = find_backlog(PhoneNumber),

    case Backlog of

        undefined ->  update_backlog(PhoneNumber, [Message]);
        no_such_user -> no_such_user;

        Messages ->

            AppendedMessages = lists:append(Messages, [Message]),
            update_backlog(PhoneNumber, AppendedMessages)

    end.

% create_user_to_room(Name, RoomId)
% leave_room(Name, RoomId)
% delete_room(Name, RoomId) % to verify that he's indeed the admin of the room

%%%%%%%%%%%%%%%%%%%%
%%% Auxilliary functions
%%%%%%%%%%%%%%%%%%%%

random_id_generator() -> 
    <<I:160/integer>> = crypto:hash(sha,term_to_binary({make_ref(), now()})), 
    erlang:integer_to_list(I, 16).

handle_list(List) ->
    ParsedList = case is_binary(List) of
        true ->
            jsx:decode(List);
        false ->
            List
    end,
    convert_list_items_to_binary(ParsedList).


convert_list_items_to_binary(List) ->
    F = fun(Item) ->
        if 
            is_list(Item) ->
                list_to_binary(Item);
            is_number(Item) ->
                list_to_binary(integer_to_list(Item));
            true ->
                Item
        end
    end,
    lists:map(F, List).

% trim_whitespace(Input) ->
%    string:strip(Input, both, $\r).

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.