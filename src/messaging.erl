-module(messaging).

-export([send_status/2, send_status/3, send_status/4, send_status_queue/3, send_status_queue/4, send_status_queue/5, send_message/2, send_message/3]).

% These versions of send_status
% do not support backlogging because they are sent at a point in the application flow
% where a valid phone number has not been successfully obtained

send_status(Socket, Status) ->
    io:format("Status sent: ~p~n", [Status]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status})).

send_status(Socket, Status, Type) ->
    io:format("Status sent: ~p with type: ~p~n", [Status, Type]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type})).

send_status(Socket, Status, Type, Message) ->
    io:format("Status sent: ~p with type: ~p and message ~p~n", [Status, Type, Message]),
    gen_tcp:send(Socket, jsx:encode(#{<<"status">> => Status, <<"type">> => Type, <<"message">> => Message})).

% These versions of send_status support backlogging and are simply wrappers around
% their send_message cousins

send_status_queue(Socket, PhoneNumber, Status) ->
    io:format("Status sent: ~p~n", [Status]),
    send_message(Socket, PhoneNumber, jsx:encode(#{<<"status">> => Status})).

send_status_queue(Socket, PhoneNumber, Status, Type) ->
    io:format("Status sent: ~p with type: ~p~n", [Status, Type]),
    send_message(Socket, PhoneNumber, jsx:encode(#{<<"status">> => Status, <<"type">> => Type})).

send_status_queue(Socket, PhoneNumber, Status, Type, Message) ->
    io:format("Status sent: ~p with type: ~p and message ~p~n", [Status, Type, Message]),
    send_message(Socket, PhoneNumber, jsx:encode(#{<<"status">> => Status, <<"type">> => Type, <<"message">> => Message})).

% Probably the most important function in Aurora
% -MOST- client responses go through this function

send_message(Socket, Message) ->
    gen_tcp:send(Socket, Message).

send_message(Socket, PhoneNumber, Message) ->
    Status = gen_tcp:send(Socket, Message),
    case Status of
        ok -> ok;
        _  -> 
            controller:append_backlog(PhoneNumber, Message),
            error
    end.