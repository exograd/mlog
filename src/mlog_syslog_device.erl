%% Copyright (c) 2021 Bryan Frimin <bryan@frimin.fr>.
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
%% SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
%% IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(mlog_syslog_device).

-behaviour(gen_server).

-export([start_link/2, init/1, terminate/2, stop/1]).

-export([handle_call/3, handle_cast/2, handle_info/2]).

-export([write_sync/2]).

-type options() :: #{host => uri:host(),
                     port => uri:port_number(),
                     tcp_options => [tcp_option()],
                     tls_options => [tls_option()]}.

-type tcp_option() :: gen_tcp:connect_option().
-type tls_option() :: ssl:tls_client_option().

-type state() :: #{options := options(),
                   transport => tls | tcp,
                   socket := inet:socket() | ssl:sslsocket() | undefined,
                   queue := queue:queue(unicode:chardata()),
                   backoff := backoff:backoff()}.

-spec write_sync(et_gen_server:ref(), unicode:chardata()) -> ok.
write_sync(Ref, Message) ->
  gen_server:call(Ref, {send, Message}, infinity). 

-spec start_link(et_gen_server:name(), options()) -> Result when
    Result :: {ok, pid()} | ignore | {error, term()}.
start_link(Name, Options) ->
  gen_server:start_link(Name, ?MODULE, [Options], []).

-spec stop(et_gen_server:ref()) -> ok.
stop(Ref) ->
  gen_server:stop(Ref, normal, infinity).

-spec init(list()) -> et_gen_server:init_ret(state()).
init([Options]) ->
  self() ! connect,
  Backoff = backoff:type(backoff:init(1000, 60000), jitter),
  State = #{options => Options,
            backoff => Backoff,
            socket => undefined,
            queue => queue:new()},
  {ok, State}.

-spec terminate(et_gen_server:terminate_reason(), state()) -> ok.
terminate(_Reason, #{transport := tcp, socket := Socket}) ->
  gen_tcp:close(Socket);
terminate(_Reason, #{transport := tls, socket := Socket}) ->
  _ = ssl:close(Socket),
  ok.

-spec handle_call(term(), {pid(), et_gen_server:request_id()}, state()) ->
        et_gen_server:handle_call_ret(state()).
handle_call({send, Msg}, _, #{socket := undefined, queue := Queue} = State) ->
  {reply, ok, State#{queue => queue:in(Msg, Queue)}};
handle_call({send, Msg}, _,
            #{transport := T, socket := S, queue := Q} = State) ->
  Len = iolist_size(Msg),
  Frame = [integer_to_binary(Len), $\s, Msg],
  Send = case T of tcp -> fun gen_tcp:send/2; tls -> fun ssl:send/2 end,
  case Send(S, Frame) of
    ok ->
      {reply, ok, State};
    {error, _} ->
      self() ! connect,
      {reply, ok, State#{socket => undefined, queue => queue:in(Msg, Q)}}
  end.

-spec handle_cast(term(), state()) -> et_gen_server:handle_cast_ret(state()).
handle_cast(_, State) ->
  {noreply, State}.

-spec handle_info(term(), state()) -> et_gen_server:handle_info_ret(state()).
handle_info({Event, _}, #{backoff := Backoff} = State) when
    Event =:= tcp_closed;
    Event =:= ssl_closed ->
  timer:send_after(backoff:get(Backoff), self(), connect),
  {noreply, State#{socket => undefined}};

handle_info(connect, #{options := Options, backoff := Backoff0} = State) ->
  Transport = maps:get(transport, Options, tcp),
  Host = maps:get(host, Options, <<"127.0.0.1">>),
  Port = maps:get(port, Options, 6514),
  ConnectOptions = [{active, true}] ++ options_connect_options(Options),
  HostAddress = host_address(Host),
  ConnectFun = case Transport of
                 tcp -> fun gen_tcp:connect/4;
                 tls -> fun ssl:connect/4
               end,
  case ConnectFun(HostAddress, Port, ConnectOptions, 10) of
    {ok, Socket} ->
      {_, Backoff} = backoff:succeed(Backoff0),
      self() ! flush,
      {noreply,
       State#{socket => Socket, transport => Transport, backoff => Backoff}};
    {error, _} ->
      {_, Backoff} = backoff:fail(Backoff0),
      timer:send_after(backoff:get(Backoff), self(), connect),
      {noreply,
       State#{socket := undefined, backoff => Backoff}}
  end;

handle_info(flush, #{transport := T, socket := S, queue := Q} = State) ->
  case queue:peek(Q) of
    {value, Msg} ->
      Len = iolist_size(Msg),
      Frame = [integer_to_binary(Len), $\s, Msg],
      Send = case T of tcp -> fun gen_tcp:send/2; tls -> fun ssl:send/2 end,
      case Send(S, Frame) of
        ok ->
          self() ! flush,
          {noreply, State#{queue => queue:drop(Q)}};
        {error, _} ->
          self() ! connect,
          {noreply, State#{socket => undefined}}
      end;
    empty ->
      {noreply, State#{queue => queue:new()}}
  end.

-spec options_connect_options(options()) -> [Options] when
    Options :: tcp_option() | tls_option().
options_connect_options(Options = #{transport := tls}) ->
  maps:get(tcp_options, Options, []) ++ maps:get(tls_options, Options, []);
options_connect_options(Options) ->
  maps:get(tcp_options, Options, []).

-spec host_address(uri:host()) -> inet:hostname() | inet:socket_address().
host_address(Host) ->
  %% While low level connection functions are perfectly able to connect to an
  %% IP address passed as a string, some features such as ssl peer hostname
  %% verification treat host strings as hostnames even if they represent an IP
  %% address. In the ssl case, they will check for SAN DNS names entries
  %% instead of SAN IP address entries.
  %%
  %% Therefore we check the host string to see if it is an IP address; when
  %% this is the case, we use the inet socket address format (a tuple).
  HostString = binary_to_list(Host),
  case inet:parse_address(HostString) of
    {ok, Address} ->
      Address;
    {error, _} ->
      HostString
  end.