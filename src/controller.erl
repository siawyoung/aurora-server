-module(controller).
-behaviour(gen_server).
-include_lib("stdlib/include/ms_transform.hrl").
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0]).

% we export append_backlog so that messaging.erl can use it
-export([append_backlog/2]).

% here we define the fields for each Mnesia table
-record(aurora_users, {phone_number, username, session_token, rooms, current_ip, active_socket}).
-record(aurora_chatrooms, {chatroom_id, chatroom_name, users, admin_user, expiry, group}).
-record(aurora_message_backlog, {phone_number, messages}).
-record(aurora_chat_messages, {chat_message_id, chatroom_id, from_phone_number, timestamp, message, tags}).
-record(aurora_events, {event_id, chatroom_id, event_name, event_datetime, votes}).
-record(aurora_notes, {note_id, chatroom_id, note_title, note_text, from_phone_number}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% Look ma, no state!
init([]) ->
    State = [],
    {ok, State}.

% handles the synchronous register call when registering a user
handle_call({register, ParsedJson, Socket}, _From, State) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    % check if user already exists in the database
    case user_exists(PhoneNumber) of

        user_exists ->
            
            % if it exists, we update the socket and send the user's backlog
            Status = update_user(full_update, ParsedJson, Socket),
            case Status of
                ok ->
                    messaging:send_status_queue(Socket, PhoneNumber, 1, <<"AUTH">>),
                    send_backlog(ParsedJson, Socket),
                    {reply, ok, State};
                _ ->
                    messaging:send_status_queue(Socket, PhoneNumber, 3, <<"AUTH">>),
                    {reply, error, State}
            end;

        no_such_user ->
            % if the user doesn't exist, we create the user
            Status = create_user(ParsedJson, Socket),
            case Status of
                ok ->
                    messaging:send_status_queue(Socket, PhoneNumber, 1, <<"AUTH">>),
                    {reply, ok, State};
                _ ->
                    messaging:send_status_queue(Socket, PhoneNumber, 3, <<"AUTH">>),
                    {reply, error, State}
            end
    end;
    
% handles the synchronous authorization call when authorizing each request
handle_call({authorize_request, ParsedJson}, _From, State) ->

    TokenToCheck = maps:get(session_token, ParsedJson),
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    % first check if the user exists
    case find_user(PhoneNumber) of
        #{username     := _UserName, 
        session_token  := SessionToken, 
        rooms          := _Rooms, 
        current_ip     := _IPaddress, 
        active_socket  := _Socket} ->

            % then we need check if the tokens match
            case SessionToken == TokenToCheck of
                true ->
                    {reply, authorized, State};
                false ->
                    {reply, error, State}

            end;

        _ ->
            {reply, no_such_user, State}

    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% FROM HERE ON LIES ONLY ASYNCHRONOUS GOODNESS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% responds to TEXT requests
handle_cast({send_chat_message, ParsedJson, FromSocket}, State) ->

    ChatRoomID = maps:get(chatroom_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),

    RoomInfo = find_chatroom(ChatRoomID),
    case RoomInfo of

        no_such_room -> 

            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TEXT">>, <<"No such room.">>);

        _ ->
    
            UserNumbersFound = maps:get(users, RoomInfo),

            case lists:member(FromPhoneNumber, UserNumbersFound) of

                true ->

                    case check_if_chatroom_expired(RoomInfo) of

                        false ->

                            % write the message to the database
                            % note that this chat message is not the same as the message backlog queue system
                            case create_chat_message(ParsedJson) of

                                {ok, chat_message_created, ChatMessageID} ->

                                    F = fun(UserNumber) ->
                                        User = find_user(UserNumber),
                                        send_chat_message(User, ParsedJson, ChatMessageID, FromSocket)
                                    end,

                                    lists:foreach(F, UserNumbersFound);

                                chat_message_error ->
                                    error

                            end;

                        true ->

                            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TEXT">>, <<"The chatroom has expired.">>)

                    end;

                false ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TEXT">>, <<"User does not belong in the room.">>)
                end

    end,
    {noreply, State};

% update_socket shouldn't respond, even if it fails
handle_cast({update_socket, ParsedJson, SocketToUpdate}, State) ->

    update_user(socket, ParsedJson, SocketToUpdate),
    send_backlog(ParsedJson, SocketToUpdate),
    {noreply, State};

% responds to GET_USERS requests
% Allows the client to send in an array of phone numbers
% Returns the list of all users who are registered
handle_cast({get_users, ParsedJson, FromSocket}, State) ->

    Users = maps:get(users, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
        
    % define a functional object that runs find_user for each phone number
    % to see if it belongs to an existing user
    F = fun(UserPhoneNumber) ->

        DatabaseResult = find_user(UserPhoneNumber),
        case DatabaseResult of
            #{username     := UserName,
            session_token  := _SessionToken, 
            rooms          := _Rooms, 
            current_ip     := _IPaddress, 
            active_socket  := _Socket} ->

                #{username     => UserName,
                  phone_number => UserPhoneNumber};

            no_such_user -> no_such_user
        end
    end,

    AllUsers = lists:map(F, Users),

    % filter out all users that do not exist
    FilteredUsers = lists:filter(fun(X) -> X =/= no_such_user end, AllUsers),

    messaging:send_message(FromSocket, FromPhoneNumber,
        jsx:encode(#{
            <<"users">> => FilteredUsers,
            <<"type">>  => <<"GET_USERS">>
            })),
    {noreply, State};

% responds to CREATE_SINGLE_ROOM requests
% we need to check if an existing single chatroom with the same person exists
% because it is illegal to have multiple single chatrooms with the same person
handle_cast({create_single_chatroom, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ToPhoneNumber = maps:get(to_phone_number, ParsedJson),
    InsertUsersAndGroupType = maps:merge(#{users => [FromPhoneNumber, ToPhoneNumber], group => false}, ParsedJson),

    case find_chatroom(find_single_chatroom, FromPhoneNumber, ToPhoneNumber) of

        database_error ->

            messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_SINGLE_ROOM">>, <<"There seems to be multiple instances of this single chatroom. Please consult the administrator.">>);

        no_such_room ->

            ValidateResult = validate_users([FromPhoneNumber,ToPhoneNumber]),

            case ValidateResult of

                {ok, users_validated, UserInfo} ->
            
                    DatabaseResult = create_chatroom(InsertUsersAndGroupType),
                    case DatabaseResult of
                        {ok, room_created, ChatRoomID, ChatRoomName, Users, Expiry} ->

                            messaging:send_message(FromSocket, FromPhoneNumber, 
                            jsx:encode(#{
                                <<"status">>        => 1,
                                <<"chatroom_id">>   => ChatRoomID,
                                <<"type">>          => <<"CREATE_SINGLE_ROOM">>
                            })),

                            % send status to all users
                            F = fun(User) ->
                                send_chatroom_invitation(ChatRoomID, ChatRoomName, Users, maps:get(active_socket, User), maps:get(phone_number, User), Expiry, single)
                            end,
                            lists:foreach(F, UserInfo);

                        error ->
                            messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_SINGLE_ROOM">>, <<"Database transaction error">>)
                    end;

                error ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"CREATE_SINGLE_ROOM">>, <<"Some users are invalid">>)
            end;

        FoundRoom ->

            messaging:send_message(FromSocket, FromPhoneNumber,
                jsx:encode(#{
                    <<"chatroom_id">> => maps:get(chatroom_id, FoundRoom),
                    <<"users">>       => maps:get(users, FoundRoom),
                    <<"expiry">>      => maps:get(expiry, FoundRoom),
                    <<"group">>       => false,
                    <<"type">>        => <<"SINGLE_ROOM_INVITATION">>
                }))
        end,

    {noreply, State};


% Responds to CREATE_ROOM requests
handle_cast({create_chatroom, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    RawUsers = maps:get(users, ParsedJson),

    ValidateResult = validate_users(RawUsers),

    case ValidateResult of

        {ok, users_validated, UserInfo} ->
    
            DatabaseResult = create_chatroom(ParsedJson),
            case DatabaseResult of
                {ok, room_created, ChatRoomID, ChatRoomName, Users, Expiry} ->

                    messaging:send_message(FromSocket, FromPhoneNumber, 
                    jsx:encode(#{
                        <<"status">>        => 1,
                        <<"chatroom_id">>   => ChatRoomID,
                        <<"type">>          => <<"CREATE_ROOM">>
                    })),

                    % send ROOM_INVITATION message to all invited users
                    F = fun(User) ->
                        send_chatroom_invitation(ChatRoomID, ChatRoomName, Users, maps:get(active_socket, User), maps:get(phone_number, User), Expiry, group)
                    end,
                    lists:foreach(F, UserInfo);

                error ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_ROOM">>, <<"Database transaction error">>)
            end;

        error ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"CREATE_ROOM">>, <<"Some users are invalid">>)
    end,
    {noreply, State};

% responds to ROOM_INVITATION message
% invite a user into an existing chatroom
% only admins can invite
handle_cast({room_invitation, ParsedJson, FromSocket}, State) ->
    
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ToPhoneNumber   = maps:get(to_phone_number, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),


    User = find_user(ToPhoneNumber),
    Room = find_chatroom(ChatRoomID),

    if
        User == no_such_user ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"No such user">>);
        Room == no_such_room ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"No such room">>);
        true ->

            % if the user is already in the room, we cannot invite him, d'oh
            case check_if_user_in_room(Room, ToPhoneNumber) of

                false ->

                    % and of course, we can't invite users if the chatroom is a single chatroom
                    case maps:get(group, Room) of

                        true ->

                            % only admins can invite users
                            case check_if_user_admin(FromPhoneNumber, ChatRoomID) of

                                user_is_admin ->
                                    ChatRoomName = maps:get(chatroom_name, Room),
                                    Expiry       = maps:get(expiry, Room),
                                    UpdatedUsers = add_user_to_room(Room, ToPhoneNumber),
                                    send_chatroom_invitation(ChatRoomID, ChatRoomName, UpdatedUsers, maps:get(active_socket, User), maps:get(phone_number, User), Expiry, group),
                                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"ROOM_INVITATION">>, <<"User invited successfully">>);
                                user_not_admin ->
                                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 8, <<"ROOM_INVITATION">>, <<"User is not admin of the room">>)
                            end;

                        false ->

                            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"Cannot invite people into single chatroom">>)

                        end;

                true ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"ROOM_INVITATION">>, <<"User is already in the room">>)
            end

    end,
    {noreply, State};

% responds to LEAVE_ROOM requests
% check if user is part of room and if he or she is the admin of the room
% unless the user is the only person left in the room, in which case the user will leave the room and
% delete the chat room
handle_cast({leave_room, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"LEAVE_ROOM">>) of

        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            ChatRoomID      = maps:get(chatroom_id, ParsedJson),
            Room            = find_chatroom(ChatRoomID),
            % admin cannot leave the room until they transfer admin rights
            case check_if_user_admin(FromPhoneNumber, ChatRoomID) of

            user_not_admin ->

                remove_room_from_user(ChatRoomID, FromPhoneNumber),
                remove_user_from_room(Room, FromPhoneNumber),
                messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"LEAVE_ROOM">>, #{<<"chatroom_id">> => ChatRoomID});

            user_is_admin -> 

                % if the user is the only person left in the room
                % leave the room and delete
                case length(maps:get(users, Room)) == 1 of

                    true ->

                        remove_room_from_user(ChatRoomID, FromPhoneNumber),
                        remove_user_from_room(Room, FromPhoneNumber),
                        delete_chatroom(ParsedJson),
                        messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"LEAVE_ROOM">>, #{<<"chatroom_id">> => ChatRoomID});

                    false ->

                        messaging:send_status_queue(FromSocket, FromPhoneNumber, 8, <<"LEAVE_ROOM">>, <<"User is the admin of the room. Admins cannot leave the room until they transfer admin rights.">>)
                end
            end
    end,
    {noreply, State};

% responds to TRANSFER_ADMIN request
handle_cast({transfer_admin, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ToPhoneNumber   = maps:get(to_phone_number, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),

    NewAdminUser = find_user(ToPhoneNumber),
    FoundRoom    = find_chatroom(ChatRoomID),

    if 
        NewAdminUser == no_such_user ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TRANSFER_ADMIN">>, <<"No such user">>);

        FoundRoom == no_such_room ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TRANSFER_ADMIN">>, <<"No such room">>);

        % notice the "true" branch used here - this is the "else" of Erlang
        % meaning that this branch will always be evaluated
        true ->
            case check_if_user_in_room(FoundRoom, FromPhoneNumber) and check_if_user_in_room(FoundRoom, ToPhoneNumber) of
                false ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"TRANSFER_ADMIN">>, <<"User is not a member of the chatroom.">>);
                true ->
                    case check_if_user_admin(FromPhoneNumber, ChatRoomID) of

                    user_not_admin ->
                        messaging:send_status_queue(FromSocket, FromPhoneNumber, 8, <<"TRANSFER_ADMIN">>, <<"User is not admin of the room">>);
                    user_is_admin -> 
                        update_chatroom(change_admin, ChatRoomID, ToPhoneNumber),
                        
                        messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"TRANSFER_ADMIN">>, #{<<"chatroom_id">> => ChatRoomID}),
                        
                        messaging:send_message(maps:get(active_socket, NewAdminUser), ToPhoneNumber, 
                            jsx:encode(#{
                            <<"chatroom_id">> => ChatRoomID,
                            <<"type">> => <<"NEW_ADMIN">>
                        }))

                    end
                    
            end

    end,

    {noreply, State};

% responds to GET_ROOMS request
% returns a list of all rooms belonging to a user
handle_cast({get_rooms, ParsedJson, FromSocket}, State) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    User = find_user(FromPhoneNumber),
    Rooms = maps:get(rooms, User),
    case Rooms of

        % if the user has no rooms, an empty list is returned
        undefined ->

            messaging:send_message(FromSocket, FromPhoneNumber,
            jsx:encode(#{
                <<"chatrooms">> => [],
                <<"type">> => <<"GET_ROOMS">>
            }));

        _ ->

            remove_expired_chatrooms(),

            F = fun(ChatRoomID) ->
                find_chatroom(ChatRoomID)
            end,

            RoomsInfo = lists:map(F, Rooms),
            FilteredRooms = lists:filter(fun(X) -> X =/= no_such_room end, RoomsInfo),
            messaging:send_message(FromSocket, FromPhoneNumber,
                jsx:encode(#{
                    <<"chatrooms">> => FilteredRooms,
                    <<"type">> => <<"GET_ROOMS">>
            }))

    end,
    
    {noreply, State};

% responds to GET_NOTES request
% returns a list of all notes belonging to a user
handle_cast({get_notes, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"GET_NOTES">>) of

        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            ChatRoomID      = maps:get(chatroom_id, ParsedJson),
            case find_notes(ChatRoomID) of

                no_notes ->
                    messaging:send_message(FromSocket, FromPhoneNumber,
                        jsx:encode(#{
                            <<"chatroom_id">> => ChatRoomID,
                            <<"notes">> => [],
                            <<"type">> => <<"GET_NOTES">>
                    }));
                    
                FoundNotes ->
                    io:format("~p~n", [FoundNotes]),
                    messaging:send_message(FromSocket, FromPhoneNumber,
                        jsx:encode(#{
                            <<"chatroom_id">> => ChatRoomID,
                            <<"notes">> => FoundNotes,
                            <<"type">> => <<"GET_NOTES">>
                    }))

            end
    end,
    {noreply, State};

% responds to CREATE_NOTE request
handle_cast({create_note, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"CREATE_NOTE">>) of

        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            case create_note(ParsedJson) of
                {ok, note_created, NoteID} ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"CREATE_NOTE">>, #{<<"note_id">> => NoteID});
                create_note_error ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_NOTE">>)

            end 
    end,
    {noreply, State};

% responds to EDIT_NOTE request
handle_cast({edit_note, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"EDIT_NOTE">>) of

        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            NoteID          = maps:get(note_id, ParsedJson),
            case edit_note(ParsedJson) of
                ok ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"EDIT_NOTE">>, #{<<"note_id">> => NoteID});
                _ ->
                messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"EDIT_NOTE">>, #{<<"note_id">> => NoteID})
            end
    end,
    {noreply, State};

% responds to DELETE_NOTE request
handle_cast({delete_note, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"DELETE_NOTE">>) of

        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            NoteID          = maps:get(note_id, ParsedJson),
            case delete_note(ParsedJson) of
                ok ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"DELETE_NOTE">>, #{<<"note_id">> => NoteID});
                _ ->
                messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"DELETE_NOTE">>, #{<<"note_id">> => NoteID})
            end
    end,

    {noreply, State};

% responds to CREATE_EVENT request
handle_cast({create_event, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"CREATE_EVENT">>) of
        false -> meh;
        true ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            case create_event(ParsedJson) of
                {ok, event_created, EventID} ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"CREATE_EVENT">>, #{<<"event_id">> => EventID});
                create_note_error ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"CREATE_EVENT">>)

            end
    end,
    {noreply, State};

% responds to GET_EVENTS request
handle_cast({get_events, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"GET_EVENTS">>) of

        false -> meh;
        true ->

            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            ChatRoomID = maps:get(chatroom_id, ParsedJson),

            case find_events(ChatRoomID) of

                no_events ->
                    messaging:send_message(FromSocket, FromPhoneNumber,
                        jsx:encode(#{
                            <<"chatroom_id">> => ChatRoomID,
                            <<"events">> => [],
                            <<"type">> => <<"GET_EVENTS">>
                    }));
                FoundEvents ->
                    io:format("~p~n", [FoundEvents]),
                    messaging:send_message(FromSocket, FromPhoneNumber,
                        jsx:encode(#{
                            <<"chatroom_id">> => ChatRoomID,
                            <<"events">> => FoundEvents,
                            <<"type">> => <<"GET_EVENTS">>
                    }))
            end
    end,
    {noreply, State};

% responds to VOTE_EVENT request
% users are able to place votes for events
handle_cast({vote_event, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"EVENT_VOTE">>) of
        false -> meh;
        true  ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            EventID = maps:get(event_id, ParsedJson),

            case vote_event(ParsedJson) of

                vote_already_cast ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 9, <<"EVENT_VOTE">>, #{<<"chatroom_id">> => EventID});
                ok ->
                    send_vote_message_to_room(ParsedJson, EventID, <<"EVENT_VOTE_RECEIVED">>),
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"EVENT_VOTE">>, #{<<"chatroom_id">> => EventID});
                _ -> 
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"EVENT_VOTE">>, #{<<"chatroom_id">> => EventID})
            end

    end,
    {noreply, State};

% responds to VOTE_EVENT request
% as well as remove their vote for events
handle_cast({unvote_event, ParsedJson, FromSocket}, State) ->

    case room_check(ParsedJson, FromSocket, <<"EVENT_VOTE">>) of
        false -> meh;
        true  ->

            FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
            EventID = maps:get(event_id, ParsedJson),

            case unvote_event(ParsedJson) of

                vote_not_cast_yet ->
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 9, <<"EVENT_UNVOTE">>, #{<<"chatroom_id">> => EventID});
                ok ->
                    send_vote_message_to_room(ParsedJson, EventID, <<"EVENT_UNVOTE_RECEIVED">>),
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"EVENT_UNVOTE">>, #{<<"chatroom_id">> => EventID});
                _ -> 
                    messaging:send_status_queue(FromSocket, FromPhoneNumber, 3, <<"EVENT_UNVOTE">>, #{<<"chatroom_id">> => EventID})
            end

    end,
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% COMPOSITE HELPER FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% These functions are abstracted out from the above casts
% For reusability's sake and/or easier reading
% These functions form an intermediate abstraction layer
% between handle_cast functions and the Mnesia private API below

room_check(ParsedJson, FromSocket, Type) ->
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),
    Room = find_chatroom(ChatRoomID),
    case Room of
        no_such_room ->
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, <<"GET_NOTES">>, <<"No such room">>),
            false;
        FoundRoom ->
            case check_if_user_in_room(FoundRoom, FromPhoneNumber) of

                    false ->
                        messaging:send_status_queue(FromSocket, FromPhoneNumber, 5, Type, <<"User is not a member of the chatroom.">>),
                        false;
                    true -> true
            end
    end.

send_vote_message_to_room(ParsedJson, EventID, Type) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),
    Room            = find_chatroom(ChatRoomID),
    Users           = maps:get(users, Room),

    F = fun(UserPhoneNumber) ->
        FoundUser = find_user(UserPhoneNumber),
        Socket = maps:get(active_socket, FoundUser),
        messaging:send_message(Socket, UserPhoneNumber, jsx:encode(#{
            <<"from_phone_number">> => FromPhoneNumber,
            <<"chatroom_id">>       => ChatRoomID, 
            <<"vote_timestamp">>    => timestamp_now(),
            <<"event_id">>          => EventID,
            <<"type">>              => Type
            }))
    end,

    lists:foreach(F, Users).

send_chat_message(UserFound, ParsedJson, MessageID, FromSocket) ->

    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),
    TimeStamp       = maps:get(timestamp, ParsedJson),
    ToSocket        = maps:get(active_socket, UserFound),
    ToPhoneNumber   = maps:get(phone_number, UserFound),
    Tags            = maps:get(tags, ParsedJson),

    Status = messaging:send_message(ToSocket, ToPhoneNumber,
        jsx:encode(#{
        <<"message_id">>        => MessageID,
        <<"from_phone_number">> => FromPhoneNumber,
        <<"chatroom_id">>       => ChatRoomID,
        <<"message">>           => Message,
        <<"timestamp">>         => TimeStamp,
        <<"tags">>              => Tags,
        <<"type">>              => <<"TEXT_RECEIVED">>
        })),

    case Status of
        ok ->
            % message sent successfully
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"TEXT">>, #{<<"message_id">> => MessageID, <<"to_phone_number">> => ToPhoneNumber});
        error ->
            % socket closed
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 7, <<"TEXT">>, #{<<"message_id">> => MessageID, <<"to_phone_number">> => ToPhoneNumber})
    end.

send_chatroom_invitation(ChatRoomID, ChatRoomName, Users, Socket, PhoneNumber, Expiry, Type) ->

    if
        Type == group ->

            messaging:send_message(Socket, PhoneNumber,
                jsx:encode(#{
                    <<"chatroom_id">>   => ChatRoomID,
                    <<"chatroom_name">> => ChatRoomName,
                    <<"users">>         => Users,
                    <<"type">>          => <<"ROOM_INVITATION">>,
                    <<"expiry">>        => Expiry,
                    <<"group">>         => true
                }));

        Type == single ->

            messaging:send_message(Socket, PhoneNumber,
                jsx:encode(#{
                    <<"chatroom_id">>   => ChatRoomID,
                    <<"users">>         => Users,
                    <<"type">>          => <<"SINGLE_ROOM_INVITATION">>,
                    <<"expiry">>        => Expiry,
                    <<"group">>         => false
                }))
    end,

    add_room_to_user(ChatRoomID, PhoneNumber).

check_if_user_in_room(Room, PhoneNumber) ->
    User = find_user(PhoneNumber),
    not(maps:get(rooms, User) == undefined) andalso lists:member(maps:get(chatroom_id, Room), maps:get(rooms, User)) and lists:member(PhoneNumber, maps:get(users, Room)).
    
add_room_to_user(ChatRoomID, PhoneNumber) ->
    User = find_user(PhoneNumber),
    Rooms = maps:get(rooms, User),
    case Rooms of
        undefined -> 
            update_user(rooms, PhoneNumber, [ChatRoomID]);

        ExistingRooms ->
            AppendedRooms = lists:append(ExistingRooms, [ChatRoomID]),
            update_user(rooms, PhoneNumber, AppendedRooms)
    end.

remove_room_from_user(ChatRoomID, PhoneNumber) ->
    User = find_user(PhoneNumber),
    Rooms = maps:get(rooms, User),
    UpdatedRooms = lists:delete(ChatRoomID, Rooms),
    update_user(rooms, PhoneNumber, UpdatedRooms).

add_user_to_room(Room, PhoneNumber) ->
    AppendedUsers = lists:append(maps:get(users, Room), [PhoneNumber]),
    update_chatroom(change_room_users, maps:get(chatroom_id, Room), AppendedUsers).

remove_user_from_room(Room, PhoneNumber) ->
    UpdatedUsers = lists:delete(PhoneNumber, maps:get(users, Room)),
    update_chatroom(change_room_users, maps:get(chatroom_id, Room), UpdatedUsers).

validate_users(Users) ->
    
    F = fun(UserPhoneNumber) ->

        DatabaseResult = find_user(UserPhoneNumber),
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
                        chat_message_delivery_receipt(PhoneNumber, Message),
                        great;
                    _  ->
                        lists:append(LeftoverMessages, [Message])
                end

            end,

            lists:foreach(F, Messages),
            update_backlog(PhoneNumber, LeftoverMessages)


    end.

%% I'm manually reparsing the message
%% It should be fine because I'm assuming all chat messages are well formed (its generated by me anyway)
%% This function sends a delivery receipt to the original sender when a previously offline user comes online
%% and backlogged chat messages are successfully delivered to him
chat_message_delivery_receipt(ToPhoneNumber, Message) ->
    ParsedMessage = jsx:decode(Message, [{labels, atom}, return_maps]),
    MessageType = maps:get(type, ParsedMessage),

    case MessageType of
        <<"TEXT_RECEIVED">> ->
            FromPhoneNumber = maps:get(from_phone_number, ParsedMessage),
            MessageID = maps:get(message_id, ParsedMessage),
            OriginalUser = find_user(FromPhoneNumber),
            FromSocket = maps:get(active_socket, OriginalUser),
            messaging:send_status_queue(FromSocket, FromPhoneNumber, 1, <<"TEXT">>, #{<<"message_id">> => MessageID, <<"to_phone_number">> => ToPhoneNumber});
        _ ->
            nothing_happens
    end.

check_if_user_admin(PhoneNumber, ChatRoomID) ->

    Room = find_chatroom(ChatRoomID),
    RoomAdmin = maps:get(admin_user, Room),

    case RoomAdmin == PhoneNumber of
        true -> user_is_admin;
        false -> user_not_admin
    end.

%%%%%%%%%%%%%%%%%%%%%%
%%% Private Mnesia API
%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This API is kept private for a number of reasons
% Easier to debug database errors
% and for security reasons as well
% we can't allow any old function to modify the
% database now, can we?
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
            _ ->
                no_such_user
        end
    end,
    mnesia:activity(transaction, F).

update_user(full_update, ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),

    case inet:peername(Socket) of

        {ok, {IPaddress, _Port}} ->

            F = fun() ->
                [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
                UpdatedUser = ExistingUser#aurora_users{username      = UserName, 
                                                        session_token = SessionToken,
                                                        current_ip    = IPaddress,
                                                        active_socket = Socket},
                mnesia:write(UpdatedUser)
                
            end,
            mnesia:activity(transaction, F);

        _ ->

            socket_error

    end;


update_user(socket, ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),

    case inet:peername(Socket) of

        {ok, {IPaddress, _Port}} ->

            F = fun() ->
                [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
                UpdatedUser = ExistingUser#aurora_users{current_ip    = IPaddress,
                                                        active_socket = Socket},
                mnesia:write(UpdatedUser)
                
            end,
            mnesia:activity(transaction, F);

        _ ->

            socket_error

    end;

update_user(rooms, PhoneNumber, Rooms) ->
    F = fun() ->
        [ExistingUser] = mnesia:wread({aurora_users, PhoneNumber}),
        UpdatedUser = ExistingUser#aurora_users{rooms = Rooms},
        mnesia:write(UpdatedUser)
    end,
    mnesia:activity(transaction, F).

create_user(ParsedJson, Socket) ->
    PhoneNumber  = maps:get(from_phone_number, ParsedJson),
    UserName     = maps:get(username, ParsedJson),
    SessionToken = maps:get(session_token, ParsedJson),

    case inet:peername(Socket) of

        {ok, {IPaddress, _Port}} ->

            F = fun() ->
                mnesia:write(#aurora_users{phone_number = PhoneNumber, 
                                           username = UserName, 
                                           session_token = SessionToken,
                                           current_ip = IPaddress, 
                                           active_socket = Socket}),
                mnesia:write(#aurora_message_backlog{phone_number = PhoneNumber})
            end,
            mnesia:activity(transaction, F);

        _ ->

            socket_error

    end.

create_chatroom(ParsedJson) ->

    AdminUser    = maps:get(from_phone_number, ParsedJson),
    ChatRoomName = maps:get(chatroom_name, ParsedJson, null),
    Users        = maps:get(users, ParsedJson),
    Group        = maps:get(group, ParsedJson, true),
    Expiry       = binary_to_number(maps:get(expiry, ParsedJson)),

    ChatRoomID   = timestamp_now(),

    F = fun() ->
        Status = mnesia:write(#aurora_chatrooms{chatroom_id   = ChatRoomID,
                                                admin_user    = AdminUser,
                                                chatroom_name = ChatRoomName,
                                                group         = Group,
                                                expiry        = Expiry,
                                                users         = Users}),
        case Status of
            ok -> {ok, room_created, ChatRoomID, ChatRoomName, Users, Expiry};
            _  -> error
        end

    end,
    mnesia:activity(transaction, F).

find_chatroom(find_single_chatroom, PhoneNumber1, PhoneNumber2) ->

    Permutation1 = [PhoneNumber1,PhoneNumber2],
    Permutation2 = [PhoneNumber2,PhoneNumber1],

    F = fun() ->
        case mnesia:match_object({aurora_chatrooms, '_', '_', Permutation1, '_', '_', false}) of
            [] ->
                case mnesia:match_object({aurora_chatrooms, '_', '_', Permutation2, '_', '_', false}) of

                    [] ->
                        no_such_room;

                    [#aurora_chatrooms{chatroom_id = ChatRoomID,
                               chatroom_name = ChatRoomName,
                               users         = RoomUsers,
                               expiry        = Expiry,
                               group         = Group,
                               admin_user    = AdminUser}] -> 

                        #{chatroom_id   => ChatRoomID,
                          chatroom_name => ChatRoomName,
                          users         => RoomUsers,
                          expiry        => list_to_binary(integer_to_list(Expiry)),
                          group         => Group,
                          admin_user    => AdminUser}
                    end;

            [#aurora_chatrooms{chatroom_id = ChatRoomID,
                               chatroom_name = ChatRoomName,
                               users         = RoomUsers,
                               expiry        = Expiry,
                               group         = Group,
                               admin_user    = AdminUser}] -> 

                #{chatroom_id   => ChatRoomID,
                  chatroom_name => ChatRoomName,
                  users         => RoomUsers,
                  expiry        => list_to_binary(integer_to_list(Expiry)),
                  group         => Group,
                  admin_user    => AdminUser};

            _ ->
                database_error
                
        end


    end,
    mnesia:activity(transaction, F).
    

find_chatroom(ChatRoomID) ->

    F = fun() ->
        case mnesia:read({aurora_chatrooms, ChatRoomID}) of
            [#aurora_chatrooms{chatroom_name = ChatRoomName,
                               users         = RoomUsers,
                               expiry        = Expiry,
                               group         = Group,
                               admin_user    = AdminUser}] ->

                #{chatroom_id   => ChatRoomID,
                  chatroom_name => ChatRoomName,
                  users         => RoomUsers,
                  expiry        => list_to_binary(integer_to_list(Expiry)),
                  group         => Group,
                  admin_user    => AdminUser};

            _ ->
                no_such_room
        end
    end,
    mnesia:activity(transaction, F).

update_chatroom(change_room_users, ChatRoomID, Users) ->
    F = fun() ->
        [ExistingRoom] = mnesia:wread({aurora_chatrooms, ChatRoomID}),
        UpdatedRoom = ExistingRoom#aurora_chatrooms{users = Users},
        mnesia:write(UpdatedRoom)
    end,
    mnesia:activity(transaction, F);

update_chatroom(change_admin, ChatRoomID, NewAdmin) ->
    F = fun() ->
        [ExistingRoom] = mnesia:wread({aurora_chatrooms, ChatRoomID}),
        UpdatedRoom = ExistingRoom#aurora_chatrooms{admin_user = NewAdmin},
        mnesia:write(UpdatedRoom)
    end,
    mnesia:activity(transaction, F).

delete_chatroom(ParsedJson) ->

    ChatRoomID = maps:get(chatroom_id, ParsedJson),

    F = fun() ->
        mnesia:delete({aurora_chatrooms, ChatRoomID})
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

create_chat_message(ParsedJson) ->
    
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    Message         = maps:get(message, ParsedJson),
    TimeStamp       = maps:get(timestamp, ParsedJson),
    Tags            = maps:get(tags, ParsedJson),
    ChatMessageID   = timestamp_now(),

    F = fun() ->
        Status = mnesia:write(#aurora_chat_messages{chatroom_id       = ChatRoomID,
                                                    from_phone_number = FromPhoneNumber,
                                                    message           = Message,
                                                    timestamp         = TimeStamp,
                                                    tags              = Tags,
                                                    chat_message_id   = ChatMessageID}),
        case Status of
            ok -> {ok, chat_message_created, ChatMessageID};
            _  -> chat_message_error
        end
    end,
    mnesia:activity(transaction, F).

find_notes(ChatRoomID) ->
    F = fun() ->
        case mnesia:match_object({aurora_notes, '_', ChatRoomID, '_', '_', '_'}) of
            [] ->
                no_notes;
            Notes ->
                F = fun(Note) ->
                    {aurora_notes, NoteID, ChatRoomID, NoteTitle, NoteText, FromPhoneNumber} = Note,
                    #{note_id => NoteID, chatroom_id => ChatRoomID, note_title => NoteTitle, note_text => NoteText, from_phone_number => FromPhoneNumber}
                end,
                lists:map(F, Notes)
        end
    end,
    mnesia:activity(transaction, F).


create_note(ParsedJson) ->

    NoteID          = timestamp_now(),
    NoteTitle       = maps:get(note_title, ParsedJson),
    NoteText        = maps:get(note_text, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),
    ChatRoomID      = maps:get(chatroom_id, ParsedJson),

    F = fun() ->

        Status = mnesia:write(#aurora_notes{note_id           = NoteID, 
                                            note_title        = NoteTitle,
                                            note_text         = NoteText,
                                            from_phone_number = FromPhoneNumber,
                                            chatroom_id       = ChatRoomID}),

        case Status of
            ok -> {ok, note_created, NoteID};
            _  -> create_note_error
        end
    end,
    mnesia:activity(transaction, F).


edit_note(ParsedJson) ->

    NoteID   = maps:get(note_id, ParsedJson),
    NoteText = maps:get(note_text, ParsedJson),

    F = fun() ->
        [ExistingNote] = mnesia:wread({aurora_notes, NoteID}),
        UpdatedNote = ExistingNote#aurora_notes{note_text = NoteText},
        mnesia:write(UpdatedNote)
    end,

    mnesia:activity(transaction, F).

delete_note(ParsedJson) ->

    NoteID = maps:get(note_id, ParsedJson),

    F = fun() ->
        mnesia:delete({aurora_notes, NoteID})
    end,
    mnesia:activity(transaction, F).

create_event(ParsedJson) ->
    
    EventID    = timestamp_now(),
    EventName  = maps:get(event_name, ParsedJson),
    ChatRoomID = maps:get(chatroom_id, ParsedJson),

    F = fun() ->

        Status = mnesia:write(#aurora_events{event_id   = EventID, 
                                            event_name  = EventName,
                                            votes       = [],
                                            chatroom_id = ChatRoomID}),

        case Status of
            ok -> {ok, event_created, EventID};
            _  -> create_event_error
        end
    end,
    mnesia:activity(transaction, F).

find_events(ChatRoomID) ->
    F = fun() ->
        case mnesia:match_object({aurora_events, '_', ChatRoomID, '_', '_'}) of
            [] ->
                no_events;
            Events ->
                F = fun(Event) ->
                    {aurora_events, EventID, ChatRoomID, EventName, Votes} = Event,
                    #{event_id => EventID, chatroom_id => ChatRoomID, event_name => EventName, votes => Votes}
                end,
                lists:map(F, Events)
        end
    end,
    mnesia:activity(transaction, F).

vote_event(ParsedJson) ->

    EventID         = maps:get(event_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),

    F = fun() ->

        [ExistingEvent] = mnesia:wread({aurora_events, EventID}),
        {aurora_events, _, _, _, _, Votes} = ExistingEvent,
        case lists:member(FromPhoneNumber, Votes) of
            true -> vote_already_cast;
            false ->
                UpdatedVotes = lists:append(Votes, [FromPhoneNumber]),
                UpdatedEvent = ExistingEvent#aurora_events{votes = UpdatedVotes},
                mnesia:write(UpdatedEvent)
        end
    end,
    mnesia:activity(transaction, F).

unvote_event(ParsedJson) ->

    EventID         = maps:get(event_id, ParsedJson),
    FromPhoneNumber = maps:get(from_phone_number, ParsedJson),

    F = fun() ->
        [ExistingEvent] = mnesia:wread({aurora_events, EventID}),
        {aurora_events, _, _, _, _, Votes} = ExistingEvent,
        case lists:member(FromPhoneNumber, Votes) of
            false -> vote_not_cast_yet;
            true ->
                UpdatedVotes = lists:delete(FromPhoneNumber, Votes),
                UpdatedEvent = ExistingEvent#aurora_events{votes = UpdatedVotes},
                mnesia:write(UpdatedEvent)
        end
    end,
    mnesia:activity(transaction, F).

%%%%%%%%%%%%%%%%%%%%%%%%
%%% Auxilliary functions
%%%%%%%%%%%%%%%%%%%%%%%%

check_if_chatroom_expired(Room) ->

    TimeNow = timestamp(now()) / 1000,
    io:format("The time now is:~p~n", [TimeNow]),

    Expiry = binary_to_number(maps:get(expiry, Room)),
    io:format("This chat room's expiry is:~p~n", [Expiry]),    
    Expiry =/= 0 andalso Expiry =< TimeNow .

remove_expired_chatrooms() ->
    
    TimeNow = timestamp(now()) / 1000,
    io:format("The time now is:~p~n", [TimeNow]),
    Match = ets:fun2ms(fun(N = #aurora_chatrooms{expiry = E}) when (E =/= 0 andalso E =< TimeNow) -> N end),
    io:format("These chatrooms are marked for deletion:~n~p~n", [Match]),

    F = fun() ->

        List = mnesia:select(aurora_chatrooms, Match),
        io:format("~p~n", [List]),
        lists:foreach(fun(X) -> mnesia:delete_object(X) end, List)

    end,
    mnesia:activity(transaction, F).

timestamp_now() ->
    list_to_binary(integer_to_list(timestamp(now()))).

timestamp({Mega, Secs, Micro}) ->
    Mega*1000*1000*1000*1000 + Secs*1000*1000 + Micro.

binary_to_number(B) ->
    list_to_number(binary_to_list(B)).

list_to_number(L) ->
    try list_to_float(L)
    catch
        error:badarg ->
            list_to_integer(L)
    end.

% Definitions to avoid gen_server compile warnings
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.