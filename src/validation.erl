-module(validation).

-export([validate_and_parse_auth/1, validate_and_parse_request/1]).

validate_and_parse_auth(RawData) ->

    case jsx:is_json(RawData) of

      false ->

        invalid_auth_message;

      true ->

        ParsedJson = jsx:decode(RawData, [{labels, atom}, return_maps]),

        Type         = maps:get(type, ParsedJson, missing_field),
        UserName     = maps:get(username, ParsedJson, missing_field),
        SessionToken = maps:get(session_token, ParsedJson, missing_field),
        PhoneNumber  = maps:get(from_phone_number, ParsedJson, missing_field),
        TimeStamp    = maps:get(timestamp, ParsedJson, missing_field),

        case ((Type =/= <<"AUTH">>) or (UserName == missing_field) or (SessionToken == missing_field) or (PhoneNumber == missing_field) or (TimeStamp == missing_field)) of

          true ->
              io:format("Message from validate_auth_message: Invalid auth message~n", []),
              invalid_auth_message;

          false ->
              io:format("Message from validate_auth_message: Valid auth message~n", []),
              ParsedJson

        end

    end.

%% Validation can fail in 3 manners:

% 1) Wrong message type - Status 6
% 2) Missing fields     - Status 2
% 3) Not JSON           - Status 0

validate_and_parse_request(RawData) ->

  case jsx:is_json(RawData) of

    false -> invalid_json;
    true ->

      ParsedJson = jsx:decode(RawData, [{labels, atom}, return_maps]),
      MessageType = get_message_type(ParsedJson),

      case MessageType of

        missing_type -> missing_fields;
        Type ->

          case Type of

            <<"AUTH">> -> wrong_message_type;
            <<"TEXT">> ->
              case validate_text_request(ParsedJson) of
                valid_request   -> ParsedJson;
                invalid_request -> {missing_fields, <<"TEXT">>}
              end;
            <<"CREATE_ROOM">> ->
              %% note that for all payloads involving lists, validation attempts to clean the list up
              %% that's why we return the payload, not an atom
              case validate_create_room_request(ParsedJson) of 
                invalid_request -> {missing_fields, <<"CREATE_ROOM">>};
                JsonWithCleanedList -> JsonWithCleanedList
              end;

            _ -> wrong_message_type
          end
      end


  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% ACTUAL VALIDATION FUNCTIONS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

validate_text_request(ParsedJson) ->
  ChatRoomId       = maps:get(chatroom_id, ParsedJson, missing_field),
  FromPhoneNumber  = maps:get(from_phone_number, ParsedJson, missing_field),
  Message          = maps:get(message, ParsedJson, missing_field),
  SessionToken     = maps:get(session_token, ParsedJson, missing_field),
  TimeStamp        = maps:get(timestamp, ParsedJson, missing_field),
  
  case ((ChatRoomId == missing_field) or (SessionToken == missing_field) or (FromPhoneNumber == missing_field) or (TimeStamp == missing_field) or (Message == missing_field)) of

    true ->
        io:format("Message from validate_text_request: Invalid payload~n", []),
        invalid_request;

    false ->
        io:format("Message from validate_auth_message: Valid payload~n", []),
        valid_request
  end.

validate_create_room_request(ParsedJson) ->
  ChatRoomName       = maps:get(chatroom_name, ParsedJson, missing_field),
  FromPhoneNumber    = maps:get(from_phone_number, ParsedJson, missing_field),
  SessionToken       = maps:get(session_token, ParsedJson, missing_field),
  TimeStamp          = maps:get(timestamp, ParsedJson, missing_field),
  Users              = maps:get(users, ParsedJson, missing_field),
  
  case ((ChatRoomName == missing_field) or (SessionToken == missing_field) or (FromPhoneNumber == missing_field) or (TimeStamp == missing_field) or (Users == missing_field)) of

    true ->
        io:format("Message from validate_create_room_request: Invalid payload~n", []),
        invalid_request;

    false ->
        io:format("Message from validate_create_room_request: Valid payload~n", []),
        maps:put(users, handle_list(Users), ParsedJson) %% we replace the old users with a cleaned version
  end.

%%%%%%%%%%%%%%%%%%%%%
% AUX
%%%%%%%%%%%%%%%%%%%%%

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