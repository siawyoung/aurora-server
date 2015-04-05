-module(validation).

-export([validate_and_parse_auth/1]).


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


