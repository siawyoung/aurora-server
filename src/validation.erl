-module(validation).

-export([validate_and_parse_auth/2, validate_and_parse_request/1]).

%% This validation method is used within pre_connected_loop
%% The only type of message we accept is AUTH messages

validate_and_parse_auth(Socket, RawData) ->

    io:format("This is the raw socket data:~n~p~n", [RawData]),

    case jsx:is_json(RawData) of

      false ->

        invalid_auth_message;

      true ->

        ParsedJson = jsx:decode(RawData, [{labels, atom}, return_maps]),
        io:format("Validating the following auth message: ~p~n", [ParsedJson]),
        Type = maps:get(type, ParsedJson, missing_field),

        case ((Type =/= <<"AUTH">>) or validate_fields([username, session_token, from_phone_number], ParsedJson)) of

          true ->
              io:format("Message from validate_auth_message: Invalid auth message~n", []),
              messaging:send_status(Socket, 2, <<"AUTH">>),
              invalid_auth_message;

          false ->
              io:format("Message from validate_auth_message: Valid auth message~n", []),
              ParsedJson

        end

    end.

%% This validation method is used within connected_loop
%% Once a socket has authenticated successfully, it is not allowed
%% to reauthenticate again

%% Validation can fail in 3 manners:

% 1) Wrong message type - Status 6
% 2) Missing fields     - Status 2
% 3) Not JSON           - Status 0

validate_and_parse_request(RawData) ->

  io:format("This is the raw socket data:~n~p~n", [RawData]),

  case jsx:is_json(RawData) of

    false -> invalid_json;
    true ->

      ParsedJson = jsx:decode(RawData, [{labels, atom}, return_maps]),
      io:format("Validating the following request: ~p~n", [ParsedJson]),
      MessageType = get_message_type(ParsedJson),

      case MessageType of

        missing_type -> missing_fields;
        Type ->

          case Type of

            <<"AUTH">> -> wrong_message_type; %% Not supposed to have AUTH messages here
            <<"TEXT">> ->
              case validate_text_request(ParsedJson) of
                invalid_request   -> {missing_fields, <<"TEXT">>};
                JsonWithCleanedList -> JsonWithCleanedList
              end;

            <<"GET_USERS">> ->
              case validate_get_users_request(ParsedJson) of
                invalid_request -> {missing_fields, <<"GET_USERS">>};
                JsonWithCleanedList -> JsonWithCleanedList
              end;

            <<"CREATE_ROOM">> ->
              %% note that for all payloads involving lists, validation attempts to clean the list up
              %% and convert the items in the list to binary strings
              %% that's why we return the payload, not an atom
              case validate_create_room_request(ParsedJson) of 
                invalid_request -> {missing_fields, <<"CREATE_ROOM">>};
                JsonWithCleanedList -> JsonWithCleanedList
              end;

            <<"CREATE_SINGLE_ROOM">> ->
              case validate_create_single_room_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"CREATE_SINGLE_ROOM">>}
              end;

            <<"ROOM_INVITATION">> ->
              case validate_chatroom_invitation_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"ROOM_INVITATION">>}
              end;

            <<"LEAVE_ROOM">> ->
              case validate_leave_room_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"LEAVE_ROOM">>}
              end;

            <<"TRANSFER_ADMIN">> ->
              case validate_transfer_admin_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"TRANSFER_ADMIN">>}
              end;

            <<"GET_ROOMS">> ->
              case validate_get_rooms_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"GET_ROOMS">>}
              end;

            <<"GET_NOTES">> ->
              case validate_get_notes_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"GET_NOTES">>}
              end;

            <<"CREATE_NOTE">> ->
              case validate_create_note_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"CREATE_NOTE">>}
              end;

            <<"EDIT_NOTE">> ->
              case validate_edit_note_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"EDIT_NOTE">>}
              end;

            <<"DELETE_NOTE">> ->
              case validate_delete_note_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"DELETE_NOTE">>}
              end; 

            <<"CREATE_EVENT">> ->
              case validate_create_event_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"CREATE_EVENT">>}
              end;

            <<"GET_EVENTS">> ->
              case validate_get_events_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"GET_EVENTS">>}
              end;

            <<"EVENT_VOTE">> ->
              case validate_event_vote_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"EVENT_VOTE">>}
              end;

            <<"EVENT_UNVOTE">> ->
              case validate_event_vote_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"EVENT_UNVOTE">>}
              end;           

            _ -> wrong_message_type
            
          end
      end


  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ACTUAL VALIDATION FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

validate_text_request(ParsedJson) ->
  
  case validate_fields([chatroom_id, session_token, from_phone_number, timestamp, message, tags], ParsedJson) of
    true ->
        io:format("Message from validate_text_request: Invalid payload~n", []),
        invalid_request;
    false ->
        Tags = maps:get(tags, ParsedJson),
        io:format("Message from validate_text_message: Valid payload~n", []),
        maps:put(tags, handle_list(Tags), ParsedJson) %% clean up the list of tags
  end.

validate_get_users_request(ParsedJson) ->

  case validate_fields([session_token, from_phone_number], ParsedJson) of
    true ->
        io:format("Message from validate_get_users_request: Invalid payload~n", []),
        invalid_request;
    false ->
        Users = maps:get(users, ParsedJson),
        io:format("Message from validate_get_users_request: Valid payload~n", []),
        maps:put(users, handle_list(Users), ParsedJson) %% we replace the old users with a cleaned version
  end.

validate_create_single_room_request(ParsedJson) ->

  case validate_fields([session_token, from_phone_number, to_phone_number, expiry], ParsedJson) of
    true ->
        io:format("Message from validate_create_single_room_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_create_single_room_request: Valid payload~n", []),
        valid_request
  end.

validate_create_room_request(ParsedJson) ->
  
  case validate_fields([chatroom_name, session_token, from_phone_number, users, expiry], ParsedJson) of
    true ->
        io:format("Message from validate_create_room_request: Invalid payload~n", []),
        invalid_request;
    false ->
        Users = maps:get(users, ParsedJson),
        io:format("Message from validate_create_room_request: Valid payload~n", []),
        maps:put(users, handle_list(Users), ParsedJson) %% we replace the old users with a cleaned version
  end.

validate_chatroom_invitation_request(ParsedJson) ->

  case validate_fields([from_phone_number, to_phone_number, session_token, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_chatroom_invitation_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_chatroom_invitation_request: Valid payload~n", []),
        valid_request
  end.

validate_leave_room_request(ParsedJson) ->
  
  case validate_fields([from_phone_number, chatroom_id, session_token], ParsedJson) of
    true ->
        io:format("Message from validate_leave_room_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_leave_room_request: Valid payload~n", []),
        valid_request
  end.

% because the payload requirements are exactly the same (for now)
validate_transfer_admin_request(ParsedJson) ->
  validate_chatroom_invitation_request(ParsedJson).

validate_get_rooms_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token], ParsedJson) of
    true ->
        io:format("Message from validate_get_rooms_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_get_rooms_request: Valid payload~n", []),
        valid_request
  end.

validate_get_notes_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_get_notes_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_get_notes_request: Valid payload~n", []),
        valid_request
  end.

validate_create_note_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, chatroom_id, note_title, note_text], ParsedJson) of
    true ->
        io:format("Message from validate_create_note_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_create_note_request: Valid payload~n", []),
        valid_request
  end.

validate_edit_note_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, note_id, note_text, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_edit_note_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_edit_note_request: Valid payload~n", []),
        valid_request
  end.

validate_delete_note_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, note_id, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_delete_note_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_delete_note_request: Valid payload~n", []),
        valid_request
  end.

validate_create_event_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, event_name, chatroom_id, event_datetime], ParsedJson) of
    true ->
        io:format("Message from validate_create_event_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_create_event_request: Valid payload~n", []),
        valid_request
  end.
  

validate_get_events_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_get_events_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_get_events_request: Valid payload~n", []),
        valid_request
  end.

validate_event_vote_request(ParsedJson) ->
  case validate_fields([from_phone_number, session_token, event_id, chatroom_id], ParsedJson) of
    true ->
        io:format("Message from validate_event_vote_request: Invalid payload~n", []),
        invalid_request;
    false ->
        io:format("Message from validate_event_vote_request: Valid payload~n", []),
        valid_request
  end.

%%%%%%%%%%%%%%%%%%%%%%
% AUXILLIARY FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%

validate_fields(Fields, ParsedJson) ->

  F = fun(Field) ->
    maps:get(Field, ParsedJson, missing_field)
  end,

  Items = lists:map(F, Fields),
  check_missing_or_null(Items).

check_missing_or_null(Items) ->
  (lists:member(missing_field, Items)) or (lists:member(null, Items)).

get_message_type(ParsedJson) ->
    maps:get(type, ParsedJson, missing_type).

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