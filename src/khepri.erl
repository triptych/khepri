%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright © 2021-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% @doc Khepri database API.
%%
%% This module exposes the database API to manipulate data.
%%
%% The API is mainly made of the functions used to perform simple direct atomic
%% operations and queries on the database: {@link get/1}, {@link put/2}, {@link
%% delete/1} and so on. In addition to that, {@link transaction/1} is the
%% starting point to run transaction functions. However the API to use inside
%% transaction functions is provided by {@link khepri_tx}.
%%
%% Functions in this module have simplified return values to cover most
%% frequent use cases. If you need more details about the queried or modified
%% tree nodes, like the ability to distinguish a non-existent tree node from a
%% tree node with no payload, you can use the {@link khepri_adv} module.
%%
%% This module also provides functions to start and stop a simple unclustered
%% Khepri store. For more advanced setup and clustering, see {@link
%% khepri_cluster}.
%%
%% == A Khepri store ==
%%
%% A Khepri store is one instance of Khepri running inside a Ra cluster (which
%% could be made of a single Erlang node). It is possible to run multiple
%% Khepri stores in parallel by creating multiple Ra clusters.
%%
%% A Khepri store is started and configured with {@link start/0}, {@link
%% start/1} or {@link start/3}. To setup a cluster, see {@link
%% khepri_cluster}.
%%
%% When a store is started, a store ID {@link store_id()} is returned. This
%% store ID is then used by the rest of this module's API. The returned store
%% ID currently corresponds exactly to the Ra cluster name. It must be an atom
%% though; other types are unsupported.
%%
%% == Interacting with the Khepri store ==
%%
%% The API provides two ways to interact with a Khepri store:
%% <ul>
%% <li>Direct atomic function for simple operations</li>
%% <li>Transactions for more complex operations</li>
%% </ul>
%%
%% Simple operations are calls like:
%% <ul>
%% <li>Queries: {@link get/1}, {@link exists/1}, {@link has_data/1}, etc.</li>
%% <li>Updates: {@link put/2}, {@link delete/1}, etc.</li>
%% </ul>
%%
%% Transactions are like Mnesia ones. The caller passes an anonymous function
%% to {@link transaction/1}, etc.:
%% ```
%% khepri:transaction(
%%   fun() ->
%%       khepri_tx:put(Path, Value)
%%   end).
%% '''
%%
%% Simple operations are more efficient than transactions, but transactions are
%% more flexible.

-module(khepri).

-include_lib("kernel/include/logger.hrl").

-include("include/khepri.hrl").
-include("src/khepri_cluster.hrl").
-include("src/khepri_error.hrl").
-include("src/khepri_fun.hrl").
-include("src/khepri_ret.hrl").

-export([
         %% Functions to start & stop a Khepri store; for more
         %% advanced functions, including clustering, see `khepri_cluster'.
         start/0, start/1, start/2, start/3,
         reset/0, reset/1, reset/2,
         stop/0, stop/1,
         get_store_ids/0,

         %% Simple direct atomic operations & queries.
         get/1, get/2, get/3,
         get_or/2, get_or/3, get_or/4,
         get_many/1, get_many/2, get_many/3,
         get_many_or/2, get_many_or/3, get_many_or/4,

         exists/1, exists/2, exists/3,
         has_data/1, has_data/2, has_data/3,
         is_sproc/1, is_sproc/2, is_sproc/3,

         count/1, count/2, count/3,

         run_sproc/2, run_sproc/3, run_sproc/4,

         put/2, put/3, put/4,
         put_many/2, put_many/3, put_many/4,
         create/2, create/3, create/4,
         update/2, update/3, update/4,
         compare_and_swap/3, compare_and_swap/4, compare_and_swap/5,

         delete/1, delete/2, delete/3,
         delete_many/1, delete_many/2, delete_many/3,
         delete_payload/1, delete_payload/2, delete_payload/3,
         delete_many_payloads/1, delete_many_payloads/2,
         delete_many_payloads/3,

         register_trigger/3, register_trigger/4, register_trigger/5,

         %% Transactions; `khepri_tx' provides the API to use inside
         %% transaction functions.
         transaction/1, transaction/2, transaction/3, transaction/4,

         wait_for_async_ret/1, wait_for_async_ret/2,

         'put!'/2, 'put!'/3, 'put!'/4,
         'create!'/2, 'create!'/3, 'create!'/4,
         'update!'/2, 'update!'/3, 'update!'/4,
         'compare_and_swap!'/3, 'compare_and_swap!'/4, 'compare_and_swap!'/5,
         'get!'/1, 'get!'/2, 'get!'/3,
         'delete!'/1, 'delete!'/2, 'delete!'/3,

         info/0,
         info/1, info/2]).

-compile({no_auto_import, [get/1, get/2, put/2, erase/1]}).

%% FIXME: Dialyzer complains about several functions with "optional" arguments
%% (but not all). I believe the specs are correct, but can't figure out how to
%% please Dialyzer. So for now, let's disable this specific check for the
%% problematic functions.
-dialyzer({no_underspecs, [start/1, start/2,
                           stop/0, stop/1,

                           put/2, put/3,
                           create/2, create/3,
                           update/2, update/3,
                           compare_and_swap/3, compare_and_swap/4,
                           exists/2,
                           has_data/2,
                           is_sproc/2,
                           run_sproc/3,
                           transaction/2, transaction/3,

                           unwrap_result/1]}).

-type store_id() :: atom().
%% ID of a Khepri store.
%%
%% This is the same as the Ra cluster name hosting the Khepri store.

-type data() :: any().
%% Data stored in a tree node's payload.

-type payload_version() :: pos_integer().
%% Number of changes made to the payload of a tree node.
%%
%% The payload version starts at 1 when a tree node is created. It is increased
%% by 1 each time the payload is added, modified or removed.

-type child_list_version() :: pos_integer().
%% Number of changes made to the list of child nodes of a tree node (child
%% nodes added or removed).
%%
%% The child list version starts at 1 when a tree node is created. It is
%% increased by 1 each time a child is added or removed. Changes made to
%% existing nodes are not reflected in this version.

-type child_list_length() :: non_neg_integer().
%% Number of direct child nodes under a tree node.

-type node_props() ::
    #{data => khepri:data(),
      has_data => boolean(),
      sproc => khepri_fun:standalone_fun(),
      is_sproc => boolean(),
      payload_version => khepri:payload_version(),
      child_list_version => khepri:child_list_version(),
      child_list_length => khepri:child_list_length(),
      child_names => [khepri_path:node_id()]}.
%% Structure used to return properties, payload and child nodes for a specific
%% tree node.
%%
%% The payload in `data' or `sproc' is only returned if the tree node carries
%% something. If that key is missing from the returned properties map, it means
%% the tree node has no payload.
%%
%% By default, the payload (if any) and its version are returned by functions
%% exposed by {@link khepri_adv}. The list of returned properties can be
%% configured using the `props_to_return' option (see {@link tree_options()}).

-type trigger_id() :: atom().
%% An ID to identify a registered trigger.

-type async_option() :: boolean() |
                        ra_server:command_correlation() |
                        ra_server:command_priority() |
                        {ra_server:command_correlation(),
                         ra_server:command_priority()}.
%% Option to indicate if the command should be synchronous or asynchronous.
%%
%% Values are:
%% <ul>
%% <li>`true' to perform an asynchronous low-priority command without a
%% correlation ID.</li>
%% <li>`false' to perform a synchronous command.</li>
%% <li>A correlation ID to perform an asynchronous low-priority command with
%% that correlation ID.</li>
%% <li>A priority to perform an asynchronous command with the specified
%% priority but without a correlation ID.</li>
%% <li>A combination of a correlation ID and a priority to perform an
%% asynchronous command with the specified parameters.</li>
%% </ul>

-type favor_option() :: consistency | compromise | low_latency.
%% Option to indicate where to put the cursor between freshness of the
%% returned data and low latency of queries.
%%
%% Values are:
%% <ul>
%% <li>`consistent' means that a "consistent query" will be used in Ra. It
%% will return the most up-to-date piece of data the cluster agreed on. Note
%% that it could block and eventually time out if there is no quorum in the Ra
%% cluster.</li>
%% <li>`compromise' performs "leader queries" most of the time to reduce
%% latency, but uses "consistent queries" every 10 seconds to verify that the
%% cluster is healthy on a regular basis. It should be faster but may block
%% and time out like `consistent' and still return slightly out-of-date
%% data.</li>
%% <li>`low_latency' means that "local queries" are used exclusively. They are
%% the fastest and have the lowest latency. However, the returned data is
%% whatever the local Ra server has. It could be out-of-date if it has
%% troubles keeping up with the Ra cluster. The chance of blocking and timing
%% out is very small.</li>
%% </ul>

-type command_options() :: #{timeout => timeout(),
                             async => async_option()}.
%% Options used in commands.
%%
%% Commands are {@link put/5}, {@link delete/3} and read-write {@link
%% transaction/4}.
%%
%% <ul>
%% <li>`timeout' is passed to Ra command processing function.</li>
%% <li>`async' indicates the synchronous or asynchronous nature of the
%% command; see {@link async_option()}.</li>
%% </ul>

-type query_options() :: #{timeout => timeout(),
                           favor => favor_option()}.
%% Options used in queries.
%%
%% <ul>
%% <li>`timeout' is passed to Ra query processing function.</li>
%% <li>`favor' indicates where to put the cursor between freshness of the
%% returned data and low latency of queries; see {@link favor_option()}.</li>
%% </ul>

-type tree_options() :: #{expect_specific_node => boolean(),
                          props_to_return => [payload_version |
                                              child_list_version |
                                              child_list_length |
                                              child_names |
                                              payload |
                                              has_payload],
                          include_root_props => boolean()}.
%% Options used during tree traversal.
%%
%% <ul>
%% <li>`expect_specific_node' indicates if the path is expected to point to a
%% specific tree node or could match many nodes.</li>
%% <li>`props_to_return' indicates the list of properties to include in the
%% returned tree node properties map. The default is `[payload,
%% payload_version]'. Note that `payload' and `has_payload' are a bit special:
%% the actually returned properties will be `data'/`sproc' and
%% `has_data'/`is_sproc' respectively.</li>
%% <li>`include_root_props' indicates if root properties and payload should be
%% returned as well.</li>
%% </ul>

-type put_options() :: #{keep_while => khepri_condition:keep_while()}.
%% Options specific to updates.
%%
%% <ul>
%% <li>`keep_while' allows to define keep-while conditions on the
%% created/updated tree node.</li>
%% </ul>

-type ok(Type) :: {ok, Type}.
%% The result of a function after a successful call, wrapped in an "ok" tuple.

-type error(Type) :: {error, Type}.
%% Return value of a failed command or query.

-type error() :: error(any()).
%% The error tuple returned by a function after a failure.

-type minimal_ret() :: ok | khepri:error().
%% The return value of update functions in the {@link khepri} module.

-type payload_ret(Default) :: khepri:ok(khepri:data() |
                                        khepri_fun:standalone_fun() |
                                        Default) |
                              khepri:error().
%% The return value of query functions in the {@link khepri} module that work
%% on a single tree node.
%%
%% `Default' is the value to return if a tree node has no payload attached to
%% it.

-type payload_ret() :: payload_ret(undefined).
%% The return value of query functions in the {@link khepri} module that work
%% on a single tree node.
%%
%% `undefined' is returned if a tree node has no payload attached to it.

-type many_payloads_ret(Default) :: khepri:ok(#{khepri_path:path() =>
                                                khepri:data() |
                                                khepri_fun:standalone_fun() |
                                                Default}) |
                                    khepri:error().
%% The return value of query functions in the {@link khepri} module that work
%% on many nodes.
%%
%% `Default' is the value to return if a tree node has no payload attached to
%% it.

-type many_payloads_ret() :: many_payloads_ret(undefined).
%% The return value of query functions in the {@link khepri} module that work
%% on a many nodes.
%%
%% `undefined' is returned if a tree node has no payload attached to it.

-export_type([store_id/0,
              ok/1,
              error/0, error/1,

              data/0,
              payload_version/0,
              child_list_version/0,
              child_list_length/0,
              node_props/0,
              trigger_id/0,

              async_option/0,
              favor_option/0,
              command_options/0,
              query_options/0,
              tree_options/0,
              put_options/0,

              minimal_ret/0,
              payload_ret/0, payload_ret/1,
              many_payloads_ret/0, many_payloads_ret/1,
              unwrapped_minimal_ret/0,
              unwrapped_payload_ret/0,
              unwrapped_payload_ret/1,
              unwrapped_many_payloads_ret/0,
              unwrapped_many_payloads_ret/1]).

%% -------------------------------------------------------------------
%% Service management.
%% -------------------------------------------------------------------

-spec start() -> Ret when
      Ret :: khepri:ok(StoreId) | khepri:error(),
      StoreId :: khepri:store_id().
%% @doc Starts a store.
%%
%% @see khepri_cluster:start/0.

start() ->
    khepri_cluster:start().

-spec start(RaSystem | DataDir) -> Ret when
      RaSystem :: atom(),
      DataDir :: file:filename_all(),
      Ret :: khepri:ok(StoreId) | khepri:error(),
      StoreId :: khepri:store_id().
%% @doc Starts a store.
%%
%% @see khepri_cluster:start/1.

start(RaSystemOrDataDir) ->
    khepri_cluster:start(RaSystemOrDataDir).

-spec start(RaSystem | DataDir, StoreId | RaServerConfig) -> Ret when
      RaSystem :: atom(),
      DataDir :: file:filename_all(),
      StoreId :: store_id(),
      RaServerConfig :: khepri_cluster:incomplete_ra_server_config(),
      Ret :: khepri:ok(StoreId) | khepri:error(),
      StoreId :: khepri:store_id().
%% @doc Starts a store.
%%
%% @see khepri_cluster:start/2.

start(RaSystemOrDataDir, StoreIdOrRaServerConfig) ->
    khepri_cluster:start(RaSystemOrDataDir, StoreIdOrRaServerConfig).

-spec start(RaSystem | DataDir, StoreId | RaServerConfig, Timeout) ->
    Ret when
      RaSystem :: atom(),
      DataDir :: file:filename_all(),
      StoreId :: store_id(),
      RaServerConfig :: khepri_cluster:incomplete_ra_server_config(),
      Timeout :: timeout(),
      Ret :: khepri:ok(StoreId) | khepri:error(),
      StoreId :: khepri:store_id().
%% @doc Starts a store.
%%
%% @see khepri_cluster:start/3.

start(RaSystemOrDataDir, StoreIdOrRaServerConfig, Timeout) ->
    khepri_cluster:start(
      RaSystemOrDataDir, StoreIdOrRaServerConfig, Timeout).

-spec reset() -> Ret when
      Ret :: ok | error().
%% @doc Resets the store on this Erlang node.
%%
%% @see khepri_cluster:reset/0.

reset() ->
    khepri_cluster:reset().

-spec reset(StoreId | Timeout) -> Ret when
      StoreId :: khepri:store_id(),
      Timeout :: timeout(),
      Ret :: ok | khepri:error().
%% @doc Resets the store on this Erlang node.
%%
%% @see khepri_cluster:reset/1.

reset(StoreIdOrTimeout) ->
    khepri_cluster:reset(StoreIdOrTimeout).

-spec reset(StoreId, Timeout) -> Ret when
      StoreId :: khepri:store_id(),
      Timeout :: timeout(),
      Ret :: ok | error().
%% @doc Resets the store on this Erlang node.
%%
%% @see khepri_cluster:reset/2.

reset(StoreId, Timeout) ->
    khepri_cluster:reset(StoreId, Timeout).

-spec stop() -> Ret when
      Ret :: ok | khepri:error().
%% @doc Stops a store.
%%
%% @see khepri_cluster:stop/0.

stop() ->
    khepri_cluster:stop().

-spec stop(StoreId) -> Ret when
      StoreId :: khepri:store_id(),
      Ret :: ok | khepri:error().
%% @doc Stops a store.
%%
%% @see khepri_cluster:stop/1.

stop(StoreId) ->
    khepri_cluster:stop(StoreId).

-spec get_store_ids() -> [StoreId] when
      StoreId :: store_id().
%% @doc Returns the list of running stores.
%%
%% @see khepri_cluster:get_store_ids/0.

get_store_ids() ->
    khepri_cluster:get_store_ids().

%% -------------------------------------------------------------------
%% get().
%% -------------------------------------------------------------------

-spec get(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:payload_ret().
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern.
%%
%% Calling this function is the same as calling `get(StoreId, PathPattern)'
%% with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see get/2.
%% @see get/3.

get(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get(StoreId, PathPattern).

-spec get
(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:payload_ret();
(PathPattern, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:payload_ret().
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get(StoreId, PathPattern)'. Calling it is the same as calling
%% `get(StoreId, PathPattern, #{})'.</li>
%% <li>`get(PathPattern, Options)'. Calling it is the same as calling
%% `get(StoreId, PathPattern, Options)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see get/3.

get(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    get(StoreId, PathPattern, #{});
get(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get(StoreId, PathPattern, Options).

-spec get(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:payload_ret().
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% The returned `{ok, Payload}' tuple contains the payload of the targeted
%% tree node, or `{ok, undefined}' if the tree node had no payload.
%%
%% Example: query a tree node which holds the atom `value'
%% ```
%% %% Query the tree node at `/:foo/:bar'.
%% {ok, value} = khepri:get(StoreId, [foo, bar]).
%% '''
%%
%% Example: query an existing tree node with no payload
%% ```
%% %% Query the tree node at `/:no_payload'.
%% {ok, undefined} = khepri:get(StoreId, [no_payload]).
%% '''
%%
%% Example: query a non-existent tree node
%% ```
%% %% Query the tree node at `/:non_existent'.
%% {error, ?khepri_error(node_not_found, _)} = khepri:get(
%%                                               StoreId, [non_existent]).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to get.
%% @param Options query options.
%%
%% @returns an `{ok, Payload | undefined}' tuple or an `{error, Reason}'
%% tuple.
%%
%% @see get_or/3.
%% @see get_many/3.
%% @see khepri_adv:get/3.

get(StoreId, PathPattern, Options) ->
    case khepri_adv:get(StoreId, PathPattern, Options) of
        {ok, #{data := Data}}           -> {ok, Data};
        {ok, #{sproc := StandaloneFun}} -> {ok, StandaloneFun};
        {ok, _}                         -> {ok, undefined};
        Error                           -> Error
    end.

%% -------------------------------------------------------------------
%% get_or().
%% -------------------------------------------------------------------

-spec get_or(PathPattern, Default) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Ret :: khepri:payload_ret(Default).
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern, or a default value.
%%
%% Calling this function is the same as calling `get_or(StoreId, PathPattern,
%% Default)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see get_or/3.
%% @see get_or/4.

get_or(PathPattern, Default) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_or(StoreId, PathPattern, Default).

-spec get_or
(StoreId, PathPattern, Default) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Ret :: khepri:payload_ret(Default);
(PathPattern, Default, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:payload_ret(Default).
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern, or a default value.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_or(StoreId, PathPattern, Default)'. Calling it is the same as
%% calling `get_or(StoreId, PathPattern, Default, #{})'.</li>
%% <li>`get_or(PathPattern, Default, Options)'. Calling it is the same as
%% calling `get_or(StoreId, PathPattern, Default, Options)' with the default
%% store ID (see {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see get_or/4.

get_or(StoreId, PathPattern, Default) when ?IS_STORE_ID(StoreId) ->
    get_or(StoreId, PathPattern, Default, #{});
get_or(PathPattern, Default, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_or(StoreId, PathPattern, Default, Options).

-spec get_or(StoreId, PathPattern, Default, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:payload_ret(Default).
%% @doc Returns the payload of the tree node pointed to by the given path
%% pattern, or a default value.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% The returned `{ok, Payload}' tuple contains the payload of the targeted
%% tree node, or `{ok, Default}' if the tree node had no payload or was not
%% found.
%%
%% Example: query a tree node which holds the atom `value'
%% ```
%% %% Query the tree node at `/:foo/:bar'.
%% {ok, value} = khepri:get_or(StoreId, [foo, bar], default).
%% '''
%%
%% Example: query an existing tree node with no payload
%% ```
%% %% Query the tree node at `/:no_payload'.
%% {ok, default} = khepri:get_or(StoreId, [no_payload], default).
%% '''
%%
%% Example: query a non-existent tree node
%% ```
%% %% Query the tree node at `/:non_existent'.
%% {ok, default} = khepri:get_or(StoreId, [non_existent], default).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to get.
%% @param Default the default value to return in case the tree node has no
%%        payload or does not exist.
%% @param Options query options.
%%
%% @returns an `{ok, Payload | Default}' tuple or an `{error, Reason}' tuple.
%%
%% @see get/3.
%% @see get_many_or/4.
%% @see khepri_adv:get/3.

get_or(StoreId, PathPattern, Default, Options) ->
    case khepri_adv:get(StoreId, PathPattern, Options) of
        {ok, #{data := Data}}                     -> {ok, Data};
        {ok, #{sproc := StandaloneFun}}           -> {ok, StandaloneFun};
        {ok, _}                                   -> {ok, Default};
        {error, ?khepri_error(node_not_found, _)} -> {ok, Default};
        Error                                     -> Error
    end.

%% -------------------------------------------------------------------
%% get_many().
%% -------------------------------------------------------------------

-spec get_many(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:many_payloads_ret().
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern.
%%
%% Calling this function is the same as calling `get_many(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see get_many/2.
%% @see get_many/3.

get_many(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_many(StoreId, PathPattern).

-spec get_many
(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:many_payloads_ret();
(PathPattern, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:many_payloads_ret().
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_many(StoreId, PathPattern)'. Calling it is the same as calling
%% `get_many(StoreId, PathPattern, #{})'.</li>
%% <li>`get_many(PathPattern, Options)'. Calling it is the same as calling
%% `get_many(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see get_many/3.

get_many(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    get_many(StoreId, PathPattern, #{});
get_many(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_many(StoreId, PathPattern, Options).

-spec get_many(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:many_payloads_ret().
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern.
%%
%% Calling this function is the same as calling `get_many_or(StoreId,
%% PathPattern, undefined, Options)'.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The returned `{ok, PayloadsMap}' tuple contains a map where keys correspond
%% to the path to a tree node matching the path pattern. Each key then points
%% to the payload of that matching tree node, or `Default' if the tree node
%% had no payload.
%%
%% Example: query all nodes in the tree
%% ```
%% %% Get all nodes in the tree. The tree is:
%% %% <root>
%% %% `-- foo
%% %%     `-- bar = value
%% {ok, #{[foo] := undefined,
%%        [foo, bar] := value}} = khepri:get_many(
%%                                  StoreId,
%%                                  [?KHEPRI_WILDCARD_STAR_STAR]).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree nodes to get.
%% @param Options query options.
%%
%% @returns an `{ok, PayloadsMap}' tuple or an `{error, Reason}' tuple.
%%
%% @see get/3.
%% @see get_many_or/4.
%% @see khepri_adv:get_many/3.

get_many(StoreId, PathPattern, Options) ->
    get_many_or(StoreId, PathPattern, undefined, Options).

%% -------------------------------------------------------------------
%% get_many_or().
%% -------------------------------------------------------------------

-spec get_many_or(PathPattern, Default) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Ret :: khepri:many_payloads_ret(Default).
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern, or a default payload.
%%
%% Calling this function is the same as calling `get_many_or(StoreId,
%% PathPattern, Default)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see get_many_or/3.
%% @see get_many_or/4.

get_many_or(PathPattern, Default) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_many_or(StoreId, PathPattern, Default).

-spec get_many_or
(StoreId, PathPattern, Default) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Ret :: khepri:many_payloads_ret(Default);
(PathPattern, Default, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:many_payloads_ret(Default).
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern, or a default payload.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_many_or(StoreId, PathPattern, Default)'. Calling it is the same as
%% calling `get_many_or(StoreId, PathPattern, Default, #{})'.</li>
%% <li>`get_many_or(PathPattern, Default, Options)'. Calling it is the same as
%% calling `get_many_or(StoreId, PathPattern, Default, Options)' with the
%% default store ID (see {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see get_many_or/4.

get_many_or(StoreId, PathPattern, Default) when ?IS_STORE_ID(StoreId) ->
    get_many_or(StoreId, PathPattern, Default, #{});
get_many_or(PathPattern, Default, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    get_many_or(StoreId, PathPattern, Default, Options).

-spec get_many_or(StoreId, PathPattern, Default, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: khepri:data(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: khepri:many_payloads_ret(Default).
%% @doc Returns payloads of all the tree nodes matching the given path
%% pattern, or a default payload.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The returned `{ok, PayloadsMap}' tuple contains a map where keys correspond
%% to the path to a tree node matching the path pattern. Each key then points
%% to the payload of that matching tree node, or `Default' if the tree node
%% had no payload.
%%
%% Example: query all nodes in the tree
%% ```
%% %% Get all nodes in the tree. The tree is:
%% %% <root>
%% %% `-- foo
%% %%     `-- bar = value
%% {ok, #{[foo] := default,
%%        [foo, bar] := value}} = khepri:get_many_or(
%%                                  StoreId,
%%                                  [?KHEPRI_WILDCARD_STAR_STAR],
%%                                  default).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree nodes to get.
%% @param Default the default value to set in `PayloadsMap' for tree nodes
%%        with no payload.
%% @param Options query options.
%%
%% @returns an `{ok, PayloadsMap}' tuple or an `{error, Reason}' tuple.
%%
%% @see get_or/4.
%% @see get_many/3.
%% @see khepri_adv:get_many/3.

get_many_or(StoreId, PathPattern, Default, Options) ->
    Ret = khepri_adv:get_many(StoreId, PathPattern, Options),
    ?many_results_ret_to_payloads_ret(Ret, Default).

%% -------------------------------------------------------------------
%% exists().
%% -------------------------------------------------------------------

-spec exists(PathPattern) -> Exists | Error when
      PathPattern :: khepri_path:pattern(),
      Exists :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path exists or not.
%%
%% Calling this function is the same as calling `exists(StoreId, PathPattern)'
%% with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see exists/2.
%% @see exists/3.

exists(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    exists(StoreId, PathPattern).

-spec exists
(StoreId, PathPattern) -> Exists | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Exists :: boolean(),
      Error :: khepri:error();
(PathPattern, Options) -> Exists | Error when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Exists :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path exists or not.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`exists(StoreId, PathPattern)'. Calling it is the same as calling
%% `exists(StoreId, PathPattern, #{})'.</li>
%% <li>`exists(PathPattern, Options)'. Calling it is the same as calling
%% `exists(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see exists/3.

exists(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    exists(StoreId, PathPattern, #{});
exists(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    exists(StoreId, PathPattern, Options).

-spec exists(StoreId, PathPattern, Options) -> Exists | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Exists :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path exists or not.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if the tree node exists, `false' if it does not, or an
%% `{error, Reason}' tuple.
%%
%% @see get/3.

exists(StoreId, PathPattern, Options) ->
    %% TODO: Use path condition instead.
    Options1 = Options#{expect_specific_node => true,
                        props_to_return => []},
    case khepri_adv:get_many(StoreId, PathPattern, Options1) of
        {ok, _} ->
            true;
        {error, ?khepri_error(node_not_found, _)} ->
            false;
        {error, _} = Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% has_data().
%% -------------------------------------------------------------------

-spec has_data(PathPattern) -> HasData | Error when
      PathPattern :: khepri_path:pattern(),
      HasData :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path has data or
%% not.
%%
%% Calling this function is the same as calling `has_data(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see has_data/2.
%% @see has_data/3.

has_data(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    has_data(StoreId, PathPattern).

-spec has_data
(StoreId, PathPattern) -> HasData | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      HasData :: boolean(),
      Error :: khepri:error();
(PathPattern, Options) -> HasData | Error when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      HasData :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path has data or
%% not.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`has_data(StoreId, PathPattern)'. Calling it is the same as calling
%% `has_data(StoreId, PathPattern, #{})'.</li>
%% <li>`has_data(PathPattern, Options)'. Calling it is the same as calling
%% `has_data(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see has_data/3.

has_data(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    has_data(StoreId, PathPattern, #{});
has_data(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    has_data(StoreId, PathPattern, Options).

-spec has_data(StoreId, PathPattern, Options) -> HasData | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      HasData :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path has data or
%% not.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if tree the node holds data, `false' if it does not exist,
%% has no payload or holds a stored procedure, or an `{error, Reason}' tuple.
%%
%% @see get/3.

has_data(StoreId, PathPattern, Options) ->
    %% TODO: Use path condition instead.
    Options1 = Options#{expect_specific_node => true,
                        props_to_return => [has_payload]},
    case khepri_adv:get_many(StoreId, PathPattern, Options1) of
        {ok, NodePropsMap} ->
            [NodeProps] = maps:values(NodePropsMap),
            maps:get(has_data, NodeProps, false);
        {error, ?khepri_error(node_not_found, _)} ->
            false;
        {error, _} = Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% is_sproc().
%% -------------------------------------------------------------------

-spec is_sproc(PathPattern) -> IsSproc | Error when
      PathPattern :: khepri_path:pattern(),
      IsSproc :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path holds a stored
%% procedure or not.
%%
%% Calling this function is the same as calling `is_sproc(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see is_sproc/2.
%% @see is_sproc/3.

is_sproc(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    is_sproc(StoreId, PathPattern).

-spec is_sproc
(StoreId, PathPattern) -> IsSproc | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      IsSproc :: boolean(),
      Error :: khepri:error();
(PathPattern, Options) -> IsSproc | Error when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      IsSproc :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path holds a stored
%% procedure or not.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`is_sproc(StoreId, PathPattern)'. Calling it is the same as calling
%% `is_sproc(StoreId, PathPattern, #{})'.</li>
%% <li>`is_sproc(PathPattern, Options)'. Calling it is the same as calling
%% `is_sproc(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see is_sproc/3.

is_sproc(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    is_sproc(StoreId, PathPattern, #{});
is_sproc(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    is_sproc(StoreId, PathPattern, Options).

-spec is_sproc(StoreId, PathPattern, Options) -> IsSproc | Error when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      IsSproc :: boolean(),
      Error :: khepri:error().
%% @doc Indicates if the tree node pointed to by the given path holds a stored
%% procedure or not.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if the tree node holds a stored procedure, `false' if it
%% does not exist, has no payload or holds data, or an `{error, Reason}'
%% tuple.
%%
%% @see get/3.

is_sproc(StoreId, PathPattern, Options) ->
    %% TODO: Use path condition instead.
    Options1 = Options#{expect_specific_node => true,
                        props_to_return => [has_payload]},
    case khepri_adv:get_many(StoreId, PathPattern, Options1) of
        {ok, NodePropsMap} ->
            [NodeProps] = maps:values(NodePropsMap),
            maps:get(is_sproc, NodeProps, false);
        {error, ?khepri_error(node_not_found, _)} ->
            false;
        {error, _} = Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% count().
%% -------------------------------------------------------------------

-spec count(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: ok(Count) | error(),
      Count :: non_neg_integer().
%% @doc Counts all tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `count(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see count/2.
%% @see count/3.

count(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    count(StoreId, PathPattern).

-spec count
(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: ok(Count) | error(),
      Count :: non_neg_integer();
(PathPattern, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: ok(Count) | error(),
      Count :: non_neg_integer().
%% @doc Counts all tree nodes matching the given path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`count(StoreId, PathPattern)'. Calling it is the same as calling
%% `count(StoreId, PathPattern, #{})'.</li>
%% <li>`count(PathPattern, Options)'. Calling it is the same as calling
%% `count(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see count/3.

count(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    count(StoreId, PathPattern, #{});
count(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    count(StoreId, PathPattern, Options).

-spec count(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: ok(Count) | error(),
      Count :: non_neg_integer().
%% @doc Counts all tree nodes matching the given path pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The root node is not included in the count.
%%
%% Example:
%% ```
%% %% Query the tree node at `/:foo/:bar'.
%% {ok, 3} = khepri:count(StoreId, [foo, ?KHEPRI_WILDCARD_STAR]).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the nodes to count.
%% @param Options query options such as `favor'.
%%
%% @returns an `{ok, Count}' tuple with the number of matching tree nodes, or
%% an `{error, Reason}' tuple.

count(StoreId, PathPattern, Options) ->
    khepri_machine:count(StoreId, PathPattern, Options).

%% -------------------------------------------------------------------
%% run_sproc().
%% -------------------------------------------------------------------

-spec run_sproc(PathPattern, Args) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Ret :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% Calling this function is the same as calling `run_sproc(StoreId,
%% PathPattern, Args)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see run_sproc/3.
%% @see run_sproc/4.

run_sproc(PathPattern, Args) ->
    StoreId = khepri_cluster:get_default_store_id(),
    run_sproc(StoreId, PathPattern, Args).

-spec run_sproc
(StoreId, PathPattern, Args) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Ret :: any();
(PathPattern, Args, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Options :: khepri:query_options() | khepri:tree_options(),
      Ret :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`run_sproc(StoreId, PathPattern, Args)'. Calling it is the same as
%% calling `run_sproc(StoreId, PathPattern, Args, #{})'.</li>
%% <li>`run_sproc(PathPattern, Args, Options)'. Calling it is the same as
%% calling `run_sproc(StoreId, PathPattern, Args, Options)' with the default
%% store ID (see {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see run_sproc/4.

run_sproc(StoreId, PathPattern, Args) when ?IS_STORE_ID(StoreId) ->
    run_sproc(StoreId, PathPattern, Args, #{});
run_sproc(PathPattern, Args, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    run_sproc(StoreId, PathPattern, Args, Options).

-spec run_sproc(StoreId, PathPattern, Args, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Options :: khepri:query_options(),
      Ret :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% The length of the `Args' list must match the number of arguments expected by
%% the stored procedure.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node holding the
%%        stored procedure.
%% @param Args the list of args to pass to the stored procedure; its length
%%        must be equal to the stored procedure arity.
%% @param Options query options.
%%
%% @returns the result of the stored procedure execution, or throws an
%% exception if the tree node does not exist, does not hold a stored procedure
%% or if there was an error.
%%
%% @see is_sproc/3.

run_sproc(StoreId, PathPattern, Args, Options) ->
    khepri_machine:run_sproc(StoreId, PathPattern, Args, Options).

%% -------------------------------------------------------------------
%% put().
%% -------------------------------------------------------------------

-spec put(PathPattern, Data) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Sets the payload of the tree node pointed to by the given path
%% pattern.
%%
%% Calling this function is the same as calling `put(StoreId, PathPattern,
%% Data)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see put/3.
%% @see put/4.

put(PathPattern, Data) ->
    StoreId = khepri_cluster:get_default_store_id(),
    put(StoreId, PathPattern, Data).

-spec put(StoreId, PathPattern, Data) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Sets the payload of the tree node pointed to by the given path
%% pattern.
%%
%% Calling this function is the same as calling `put(StoreId, PathPattern,
%% Data, #{})'.
%%
%% @see put/4.

put(StoreId, PathPattern, Data) ->
    put(StoreId, PathPattern, Data, #{}).

-spec put(StoreId, PathPattern, Data, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Sets the payload of the tree node pointed to by the given path
%% pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time.
%%
%% When using a simple path (i.e. without conditions), if the targeted tree
%% node does not exist, it is created using the given payload. If the
%% targeted tree node exists, it is updated with the given payload and its
%% payload version is increased by one. Missing parent nodes are created on
%% the way.
%%
%% When using a path pattern, the behavior is the same. However if a condition
%% in the path pattern is not met, an error is returned and the tree structure
%% is not modified.
%%
%% The payload must be one of the following form:
%% <ul>
%% <li>An explicit absence of payload ({@link khepri_payload:no_payload()}),
%% using the marker returned by {@link khepri_payload:none/0}, meaning there
%% will be no payload attached to the tree node and the existing payload will
%% be discarded if any</li>
%% <li>An anonymous function; it will be considered a stored procedure and
%% will be wrapped in a {@link khepri_payload:sproc()} record</li>
%% <li>Any other term; it will be wrapped in a {@link khepri_payload:data()}
%% record</li>
%% </ul>
%%
%% It is possible to wrap the payload in its internal structure explicitly
%% using the {@link khepri_payload} module directly.
%%
%% The `Options' map may specify command-level options; see {@link
%% khepri:command_options()}, {@link khepri:tree_options()} and {@link
%% khepri:put_options()}.
%%
%% When doing an asynchronous update, the {@link wait_for_async_ret/1}
%% function can be used to receive the message from Ra.
%%
%% Example:
%% ```
%% %% Insert a tree node at `/:foo/:bar', overwriting the previous value.
%% ok = khepri_adv:put(StoreId, [foo, bar], new_value).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see create/4.
%% @see update/4.
%% @see compare_and_swap/5.
%% @see put_many/4.
%% @see khepri_adv:put/4.

put(StoreId, PathPattern, Data, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:put(StoreId, PathPattern, Data, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% put_many().
%% -------------------------------------------------------------------

-spec put_many(PathPattern, Data) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Sets the payload of all the tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `put_many(StoreId, PathPattern,
%% Data)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see put_many/3.
%% @see put_many/4.

put_many(PathPattern, Data) ->
    StoreId = khepri_cluster:get_default_store_id(),
    put_many(StoreId, PathPattern, Data).

-spec put_many(StoreId, PathPattern, Data) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Sets the payload of all the tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `put_many(StoreId, PathPattern,
%% Data, #{})'.
%%
%% @see put_many/4.

put_many(StoreId, PathPattern, Data) ->
    put_many(StoreId, PathPattern, Data, #{}).

-spec put_many(StoreId, PathPattern, Data, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Sets the payload of all the tree nodes matching the given path pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% When using a simple path (i.e. without conditions), if the targeted tree
%% node does not exist, it is created using the given payload. If the
%% targeted tree node exists, it is updated with the given payload and its
%% payload version is increased by one. Missing parent nodes are created on
%% the way.
%%
%% When using a path pattern, the behavior is the same. However if a condition
%% in the path pattern is not met, an error is returned and the tree structure
%% is not modified.
%%
%% The payload must be one of the following form:
%% <ul>
%% <li>An explicit absence of payload ({@link khepri_payload:no_payload()}),
%% using the marker returned by {@link khepri_payload:none/0}, meaning there
%% will be no payload attached to the tree node and the existing payload will
%% be discarded if any</li>
%% <li>An anonymous function; it will be considered a stored procedure and
%% will be wrapped in a {@link khepri_payload:sproc()} record</li>
%% <li>Any other term; it will be wrapped in a {@link khepri_payload:data()}
%% record</li>
%% </ul>
%%
%% It is possible to wrap the payload in its internal structure explicitly
%% using the {@link khepri_payload} module directly.
%%
%% The `Options' map may specify command-level options; see {@link
%% khepri:command_options()}, {@link khepri:tree_options()} and {@link
%% khepri:put_options()}.
%%
%% When doing an asynchronous update, the {@link wait_for_async_ret/1}
%% function can be used to receive the message from Ra.
%%
%% Example:
%% ```
%% %% Insert a tree node at `/:foo/:bar', overwriting the previous value.
%% ok = khepri_adv:put(StoreId, [foo, bar], new_value).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see put/4.
%% @see khepri_adv:put_many/4.

put_many(StoreId, PathPattern, Data, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:put_many(StoreId, PathPattern, Data, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% create().
%% -------------------------------------------------------------------

-spec create(PathPattern, Data) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Creates a tree node with the given payload.
%%
%% Calling this function is the same as calling `create(StoreId, PathPattern,
%% Data)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see create/3.
%% @see create/4.

create(PathPattern, Data) ->
    StoreId = khepri_cluster:get_default_store_id(),
    create(StoreId, PathPattern, Data).

-spec create(StoreId, PathPattern, Data) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Creates a tree node with the given payload.
%%
%% Calling this function is the same as calling `create(StoreId, PathPattern,
%% Data, #{})'.
%%
%% @see create/4.

create(StoreId, PathPattern, Data) ->
    create(StoreId, PathPattern, Data, #{}).

-spec create(StoreId, PathPattern, Data, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Creates a tree node with the given payload.
%%
%% The behavior is the same as {@link put/4} except that if the tree node
%% already exists, an `{error, ?khepri_error(mismatching_node, Info)}' tuple is
%% returned.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_node_exists{exists = false}' condition on its last component.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to create.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see put/4.
%% @see update/4.
%% @see compare_and_swap/5.
%% @see khepri_adv:create/4.

create(StoreId, PathPattern, Data, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:create(StoreId, PathPattern, Data, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% update().
%% -------------------------------------------------------------------

-spec update(PathPattern, Data) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Updates an existing tree node with the given payload.
%%
%% Calling this function is the same as calling `update(StoreId, PathPattern,
%% Data)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see update/3.
%% @see update/4.

update(PathPattern, Data) ->
    StoreId = khepri_cluster:get_default_store_id(),
    update(StoreId, PathPattern, Data).

-spec update(StoreId, PathPattern, Data) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Updates an existing tree node with the given payload.
%%
%% Calling this function is the same as calling `update(StoreId, PathPattern,
%% Data, #{})'.
%%
%% @see update/4.

update(StoreId, PathPattern, Data) ->
    update(StoreId, PathPattern, Data, #{}).

-spec update(StoreId, PathPattern, Data, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Updates an existing tree node with the given payload.
%%
%% The behavior is the same as {@link put/4} except that if the tree node
%% already exists, an `{error, ?khepri_error(mismatching_node, Info)}' tuple is
%% returned.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_node_exists{exists = true}' condition on its last component.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see put/4.
%% @see create/4.
%% @see compare_and_swap/5.
%% @see khepri_adv:update/4.

update(StoreId, PathPattern, Data, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:update(StoreId, PathPattern, Data, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% compare_and_swap().
%% -------------------------------------------------------------------

-spec compare_and_swap(PathPattern, DataPattern, Data) -> Ret when
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Updates an existing tree node with the given payload only if its data
%% matches the given pattern.
%%
%% Calling this function is the same as calling `compare_and_swap(StoreId,
%% PathPattern, DataPattern, Data)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see compare_and_swap/4.
%% @see compare_and_swap/5.

compare_and_swap(PathPattern, DataPattern, Data) ->
    StoreId = khepri_cluster:get_default_store_id(),
    compare_and_swap(StoreId, PathPattern, DataPattern, Data).

-spec compare_and_swap(StoreId, PathPattern, DataPattern, Data) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Ret :: khepri:minimal_ret().
%% @doc Updates an existing tree node with the given payload only if its data
%% matches the given pattern.
%%
%% Calling this function is the same as calling `compare_and_swap(StoreId,
%% PathPattern, DataPattern, Data, #{})'.
%%
%% @see compare_and_swap/5.

compare_and_swap(StoreId, PathPattern, DataPattern, Data) ->
    compare_and_swap(StoreId, PathPattern, DataPattern, Data, #{}).

-spec compare_and_swap(StoreId, PathPattern, DataPattern, Data, Options) ->
    Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | khepri:data() | fun(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Updates an existing tree node with the given payload only if its data
%% matches the given pattern.
%%
%% The behavior is the same as {@link put/4} except that if the tree node
%% already exists, an `{error, ?khepri_error(mismatching_node, Info)}' tuple is
%% returned.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_data_matches{pattern = DataPattern}' condition on its last component.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see put/4.
%% @see create/4.
%% @see update/4.
%% @see khepri_adv:compare_and_swap/5.

compare_and_swap(StoreId, PathPattern, DataPattern, Data, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:compare_and_swap(
            StoreId, PathPattern, DataPattern, Data, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% delete().
%% -------------------------------------------------------------------

-spec delete(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the tree node pointed to by the given path pattern.
%%
%% Calling this function is the same as calling `delete(StoreId, PathPattern)'
%% with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see delete/2.
%% @see delete/3.

delete(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete(StoreId, PathPattern).

-spec delete
(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret();
(PathPattern, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() | khepri:tree_options(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the tree node pointed to by the given path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`delete(StoreId, PathPattern)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, #{})'.</li>
%% <li>`delete(PathPattern, Options)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see delete/3.

delete(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    delete(StoreId, PathPattern, #{});
delete(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete(StoreId, PathPattern, Options).

-spec delete(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() | khepri:tree_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Deletes the tree node pointed to by the given path pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% The `PathPattern' must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the tree node is looked up: so if a condition in the path could
%% potentially match several nodes, an exception is raised, even though only
%% one tree node would match at the time. If you want to delete multiple nodes
%% at once, use {@link delete_many/3}.
%%
%% Example:
%% ```
%% %% Delete the tree node at `/:foo/:bar'.
%% ok = khepri_adv:delete(StoreId, [foo, bar]).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the node to delete.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see delete_many/3.
%% @see khepri_adv:delete/3.

delete(StoreId, PathPattern, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:delete(StoreId, PathPattern, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% delete_many().
%% -------------------------------------------------------------------

-spec delete_many(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes all tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `delete_many(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see delete_many/2.
%% @see delete_many/3.

delete_many(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete_many(StoreId, PathPattern).

-spec delete_many
(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret();
(PathPattern, Options) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() | khepri:tree_options(),
      Ret :: khepri:minimal_ret().

%% @doc Deletes all tree nodes matching the given path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`delete_many(StoreId, PathPattern)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, #{})'.</li>
%% <li>`delete_many(PathPattern, Options)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see delete_many/3.

delete_many(StoreId, PathPattern) when ?IS_STORE_ID(StoreId) ->
    delete_many(StoreId, PathPattern, #{});
delete_many(PathPattern, Options) when is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete_many(StoreId, PathPattern, Options).

-spec delete_many(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() | khepri:tree_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Deletes all tree nodes matching the given path pattern.
%%
%% The `PathPattern' can be provided as a native path pattern (a list of tree
%% node names and conditions) or as a string. See {@link
%% khepri_path:from_string/1}.
%%
%% Example:
%% ```
%% %% Delete all nodes in the tree.
%% ok = khepri_adv:delete_many(StoreId, [?KHEPRI_WILDCARD_STAR]).
%% '''
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the nodes to delete.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see delete/3.

delete_many(StoreId, PathPattern, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:delete_many(StoreId, PathPattern, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% delete_payload().
%% -------------------------------------------------------------------

-spec delete_payload(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the payload of the tree node pointed to by the given path
%% pattern.
%%
%% Calling this function is the same as calling `delete_payload(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see delete_payload/2.
%% @see delete_payload/3.

delete_payload(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete_payload(StoreId, PathPattern).

-spec delete_payload(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the payload of the tree node pointed to by the given path
%% pattern.
%%
%% Calling this function is the same as calling `delete_payload(StoreId,
%% PathPattern, #{})'.
%%
%% @see delete_payload/3.

delete_payload(StoreId, PathPattern) ->
    delete_payload(StoreId, PathPattern, #{}).

-spec delete_payload(StoreId, PathPattern, Options) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Deletes the payload of the tree node pointed to by the given path
%% pattern.
%%
%% In other words, the payload is set to {@link khepri_payload:no_payload()}.
%% Otherwise, the behavior is that of {@link put/4}.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree node to modify.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see put/4.
%% @see khepri_adv:delete_payload/3.

delete_payload(StoreId, PathPattern, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:delete_payload(StoreId, PathPattern, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% delete_many_payloads().
%% -------------------------------------------------------------------

-spec delete_many_payloads(PathPattern) -> Ret when
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the payload of all tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `delete_many_payloads(StoreId,
%% PathPattern)' with the default store ID (see {@link
%% khepri_cluster:get_default_store_id/0}).
%%
%% @see delete_many_payloads/2.
%% @see delete_many_payloads/3.

delete_many_payloads(PathPattern) ->
    StoreId = khepri_cluster:get_default_store_id(),
    delete_many_payloads(StoreId, PathPattern).

-spec delete_many_payloads(StoreId, PathPattern) -> Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Ret :: khepri:minimal_ret().
%% @doc Deletes the payload of all tree nodes matching the given path pattern.
%%
%% Calling this function is the same as calling `delete_many_payloads(StoreId,
%% PathPattern, #{})'.
%%
%% @see delete_many_payloads/3.

delete_many_payloads(StoreId, PathPattern) ->
    delete_many_payloads(StoreId, PathPattern, #{}).

-spec delete_many_payloads(StoreId, PathPattern, Options) ->
    Ret when
      StoreId :: khepri:store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: khepri:command_options() |
                 khepri:tree_options() |
                 khepri:put_options(),
      Ret :: khepri:minimal_ret() | khepri_machine:async_ret().
%% @doc Deletes the payload of all tree nodes matching the given path pattern.
%%
%% In other words, the payload is set to {@link khepri_payload:no_payload()}.
%% Otherwise, the behavior is that of {@link put/4}.
%%
%% @param StoreId the name of the Khepri store.
%% @param PathPattern the path (or path pattern) to the tree nodes to modify.
%% @param Options command options.
%%
%% @returns in the case of a synchronous call, `ok' or an `{error, Reason}'
%% tuple; in the case of an asynchronous call, always `ok' (the actual return
%% value may be sent by a message if a correlation ID was specified).
%%
%% @see delete_many/3.
%% @see put/4.
%% @see khepri_adv:delete_many_payloads/3.

delete_many_payloads(StoreId, PathPattern, Options) ->
    Options1 = Options#{props_to_return => []},
    Ret = khepri_adv:delete_many_payloads(
            StoreId, PathPattern, Options1),
    ?result_ret_to_minimal_ret(Ret).

%% -------------------------------------------------------------------
%% register_trigger().
%% -------------------------------------------------------------------

-spec register_trigger(TriggerId, EventFilter, StoredProcPath) -> Ret when
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Ret :: ok | error().
%% @doc Registers a trigger.
%%
%% Calling this function is the same as calling `register_trigger(StoreId,
%% TriggerId, EventFilter, StoredProcPath)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).
%%
%% @see register_trigger/4.

register_trigger(TriggerId, EventFilter, StoredProcPath) ->
    StoreId = khepri_cluster:get_default_store_id(),
    register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath).

-spec register_trigger
(StoreId, TriggerId, EventFilter, StoredProcPath) -> Ret when
      StoreId :: khepri:store_id(),
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Ret :: ok | error();
(TriggerId, EventFilter, StoredProcPath, Options) -> Ret when
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Options :: command_options() | khepri:tree_options(),
      Ret :: ok | error().
%% @doc Registers a trigger.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath)'.
%% Calling it is the same as calling `register_trigger(StoreId, TriggerId,
%% EventFilter, StoredProcPath, #{})'.</li>
%% <li>`register_trigger(TriggerId, EventFilter, StoredProcPath, Options)'.
%% Calling it is the same as calling `register_trigger(StoreId, TriggerId,
%% EventFilter, StoredProcPath, Options)' with the default store ID (see
%% {@link khepri_cluster:get_default_store_id/0}).</li>
%% </ul>
%%
%% @see register_trigger/5.

register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath)
  when ?IS_STORE_ID(StoreId) andalso is_atom(TriggerId) ->
    register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath, #{});
register_trigger(TriggerId, EventFilter, StoredProcPath, Options)
  when is_atom(TriggerId) andalso is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    register_trigger(
      StoreId, TriggerId, EventFilter, StoredProcPath, Options).

-spec register_trigger(
        StoreId, TriggerId, EventFilter, StoredProcPath, Options) ->
    Ret when
      StoreId :: khepri:store_id(),
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Options :: command_options() | khepri:tree_options(),
      Ret :: ok | error().
%% @doc Registers a trigger.
%%
%% A trigger is based on an event filter. It associates an event with a stored
%% procedure. When an event matching the event filter is emitted, the stored
%% procedure is executed.
%%
%% The following event filters are documented by {@link
%% khepri_evf:event_filter()}.
%%
%% Here are examples of event filters:
%%
%% ```
%% %% An event filter can be explicitly created using the `khepri_evf'
%% %% module. This is possible to specify properties at the same time.
%% EventFilter = khepri_evf:tree([stock, wood, <<"oak">>], %% Required
%%                               #{on_actions => [delete], %% Optional
%%                                 priority => 10}).       %% Optional
%% '''
%% ```
%% %% For ease of use, some terms can be automatically converted to an event
%% %% filter. In this example, a Unix-like path can be used as a tree event
%% %% filter.
%% EventFilter = "/:stock/:wood/oak".
%% '''
%%
%% The stored procedure is expected to accept a single argument. This argument
%% is a map containing the event properties. Here is an example:
%%
%% ```
%% my_stored_procedure(Props) ->
%%     #{path := Path},
%%       on_action => Action} = Props.
%% '''
%%
%% The stored procedure is executed on the leader's Erlang node.
%%
%% It is guaranteed to run at least once. It could be executed multiple times
%% if the Ra leader changes, therefore the stored procedure must be
%% idempotent.
%%
%% @param StoreId the name of the Khepri store.
%% @param TriggerId the name of the trigger.
%% @param EventFilter the event filter used to associate an event with a
%%        stored procedure.
%% @param StoredProcPath the path to the stored procedure to execute when the
%%        corresponding event occurs.
%%
%% @returns `ok' if the trigger was registered, an `{error, Reason}' tuple
%% otherwise.

register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath, Options) ->
    khepri_machine:register_trigger(
      StoreId, TriggerId, EventFilter, StoredProcPath, Options).

%% -------------------------------------------------------------------
%% transaction().
%% -------------------------------------------------------------------

-spec transaction(Fun) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      Ret :: khepri_machine:tx_ret().
%% @doc Runs a transaction and returns its result.
%%
%% Calling this function is the same as calling `transaction(StoreId, Fun)'
%% with the default store ID.
%%
%% @see transaction/2.

transaction(Fun) ->
    StoreId = khepri_cluster:get_default_store_id(),
    transaction(StoreId, Fun).

-spec transaction
(StoreId, Fun) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      Ret :: khepri_machine:tx_ret();
(Fun, ReadWriteOrOptions) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      ReadWriteOrOptions :: ReadWrite | Options,
      ReadWrite :: ro | rw | auto,
      Options :: command_options() | query_options(),
      Ret :: khepri_machine:tx_ret() | khepri_machine:async_ret().
%% @doc Runs a transaction and returns its result.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`transaction(StoreId, Fun)'. Calling it is the same as calling
%% `transaction(StoreId, Fun, #{})'.</li>
%% <li>`transaction(Fun, Options)'. Calling it is the same as calling
%% `transaction(StoreId, Fun, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see transaction/3.

transaction(StoreId, Fun) when is_function(Fun) ->
    transaction(StoreId, Fun, auto);
transaction(Fun, ReadWriteOrOptions) when is_function(Fun) ->
    StoreId = khepri_cluster:get_default_store_id(),
    transaction(StoreId, Fun, ReadWriteOrOptions).

-spec transaction
(StoreId, Fun, ReadWrite) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Ret :: khepri_machine:tx_ret();
(StoreId, Fun, Options) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      Options :: command_options() | query_options(),
      Ret :: khepri_machine:tx_ret() | khepri_machine:async_ret();
(Fun, ReadWrite, Options) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Options :: command_options() | query_options(),
      Ret :: khepri_machine:tx_ret() | khepri_machine:async_ret().
%% @doc Runs a transaction and returns its result.
%%
%% This function accepts the following three forms:
%% <ul>
%% <li>`transaction(StoreId, PathPattern, ReadWrite)'. Calling it is the same
%% as calling `transaction(StoreId, PathPattern, ReadWrite, #{})'.</li>
%% <li>`transaction(StoreId, PathPattern, Options)'. Calling it is the same
%% as calling `transaction(StoreId, PathPattern, auto, Options)'.</li>
%% <li>`transaction(PathPattern, ReadWrite, Options)'. Calling it is the same
%% as calling `transaction(StoreId, PathPattern, ReadWrite, Options)' with the
%% default store ID.</li>
%% </ul>
%%
%% @see transaction/4.

transaction(StoreId, Fun, ReadWrite)
  when is_atom(StoreId) andalso is_atom(ReadWrite) ->
    transaction(StoreId, Fun, ReadWrite, #{});
transaction(StoreId, Fun, Options)
  when is_atom(StoreId) andalso is_map(Options) ->
    transaction(StoreId, Fun, auto, Options);
transaction(Fun, ReadWrite, Options)
  when is_atom(ReadWrite) andalso is_map(Options) ->
    StoreId = khepri_cluster:get_default_store_id(),
    transaction(StoreId, Fun, ReadWrite, Options).

-spec transaction(StoreId, Fun, ReadWrite, Options) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Options :: khepri:command_options() | khepri:query_options(),
      Ret :: khepri_machine:tx_ret() | khepri_machine:async_ret().
%% @doc Runs a transaction and returns its result.
%%
%% `Fun' is an arbitrary anonymous function which takes no arguments.
%%
%% The `ReadWrite' flag determines what the anonymous function is allowed to
%% do and in which context it runs:
%%
%% <ul>
%% <li>If `ReadWrite' is `ro', `Fun' can do whatever it wants, except modify
%% the content of the store. In other words, uses of {@link khepri_tx:put/2}
%% or {@link khepri_tx:delete/1} are forbidden and will abort the function.
%% `Fun' is executed from a process on the leader Ra member.</li>
%% <li>If `ReadWrite' is `rw', `Fun' can use the {@link khepri_tx} transaction
%% API as well as any calls to other modules as long as those functions or what
%% they do is permitted. See {@link khepri_tx} for more details. If `Fun' does
%% or calls something forbidden, the transaction will be aborted. `Fun' is
%% executed in the context of the state machine process on each Ra
%% members.</li>
%% <li>If `ReadWrite' is `auto', `Fun' is analyzed to determine if it calls
%% {@link khepri_tx:put/2} or {@link khepri_tx:delete/1}, or uses any denied
%% operations for a read/write transaction. If it does, this is the same as
%% setting `ReadWrite' to true. Otherwise, this is the equivalent of setting
%% `ReadWrite' to false.</li>
%% </ul>
%%
%% `Options' is relevant for both read-only and read-write transactions
%% (including audetected ones). However note that both types expect different
%% options.
%%
%% The result of `Fun' can be any term. That result is returned in an `{ok,
%% Result}' tuple if the transaction is synchronous. The result is sent by
%% message if the transaction is asynchronous and a correlation ID was
%% specified.
%%
%% @param StoreId the name of the Khepri store.
%% @param Fun an arbitrary anonymous function.
%% @param ReadWrite the read/write or read-only nature of the transaction.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous transaction, `{ok, Result}' where
%% `Result' is the return value of `Fun', or `{error, Reason}' if the anonymous
%% function was aborted; in the case of an asynchronous transaction, always
%% `ok' (the actual return value may be sent by a message if a correlation ID
%% was specified).

transaction(StoreId, Fun, ReadWrite, Options) ->
    khepri_machine:transaction(StoreId, Fun, ReadWrite, Options).

%% -------------------------------------------------------------------
%% wait_for_async_ret().
%% -------------------------------------------------------------------

-spec wait_for_async_ret(Correlation) -> Ret when
      Correlation :: ra_server:command_correlation(),
      Ret :: khepri:minimal_ret() |
             khepri:payload_ret() |
             khepri:many_payloads_ret() |
             khepri_adv:single_result() |
             khepri_adv:many_results() |
             khepri_machine:tx_ret().
%% @doc Waits for an asynchronous call.
%%
%% Calling this function is the same as calling
%% `wait_for_async_ret(Correlation)' with the default timeout (see {@link
%% khepri_app:get_default_timeout/0}).
%%
%% @see wait_for_async_ret/2.

wait_for_async_ret(Correlation) ->
    Timeout = khepri_app:get_default_timeout(),
    wait_for_async_ret(Correlation, Timeout).

-spec wait_for_async_ret(Correlation, Timeout) -> Ret when
      Correlation :: ra_server:command_correlation(),
      Timeout :: timeout(),
      Ret :: khepri:minimal_ret() |
             khepri:payload_ret() |
             khepri:many_payloads_ret() |
             khepri_adv:single_result() |
             khepri_adv:many_results() |
             khepri_machine:tx_ret().
%% @doc Waits for an asynchronous call.
%%
%% This function waits maximum `Timeout' milliseconds (or `infinity') for the
%% result of a previous call where the `async' option was set with a
%% correlation ID. That correlation ID must be passed to this function.
%%
%% @see wait_for_async_ret/2.

wait_for_async_ret(Correlation, Timeout) ->
    receive
        {ra_event, _, {applied, [{Correlation, Reply}]}} ->
            case Reply of
                {exception, _, _, _} = Exception ->
                    khepri_machine:handle_tx_exception(Exception);
                ok ->
                    Reply;
                {ok, _} ->
                    Reply;
                {error, _} ->
                    Reply
            end
    after Timeout ->
              {error, timeout}
    end.

-include("khepri_bang.hrl").

%% -------------------------------------------------------------------
%% Public helpers.
%% -------------------------------------------------------------------

-spec info() -> ok.
%% @doc Lists the running stores on <em>stdout</em>.

info() ->
    StoreIds = get_store_ids(),
    case StoreIds of
        [] ->
            io:format("No stores running~n");
        _ ->
            io:format("Running stores:~n"),
            lists:foreach(
              fun(StoreId) ->
                      io:format("  ~ts~n", [StoreId])
              end, StoreIds)
    end,
    ok.

-spec info(StoreId) -> ok when
      StoreId :: store_id().
%% @doc Lists the content of specified store on <em>stdout</em>.
%%
%% @param StoreId the name of the Khepri store.

info(StoreId) ->
    info(StoreId, #{}).

-spec info(StoreId, Options) -> ok when
      StoreId :: khepri:store_id(),
      Options :: khepri:query_options().
%% @doc Lists the content of specified store on <em>stdout</em>.
%%
%% @param StoreId the name of the Khepri store.

info(StoreId, Options) ->
    io:format("~n\033[1;32m== CLUSTER MEMBERS ==\033[0m~n~n", []),
    Nodes = lists:sort(
              [Node || {_, Node} <- khepri_cluster:members(StoreId)]),
    lists:foreach(fun(Node) -> io:format("~ts~n", [Node]) end, Nodes),

    case khepri_machine:get_keep_while_conds_state(StoreId, Options) of
        {ok, KeepWhileConds} when KeepWhileConds =/= #{} ->
            io:format("~n\033[1;32m== LIFETIME DEPS ==\033[0m~n", []),
            WatcherList = lists:sort(maps:keys(KeepWhileConds)),
            lists:foreach(
              fun(Watcher) ->
                      io:format("~n\033[1m~p depends on:\033[0m~n", [Watcher]),
                      WatchedsMap = maps:get(Watcher, KeepWhileConds),
                      Watcheds = lists:sort(maps:keys(WatchedsMap)),
                      lists:foreach(
                        fun(Watched) ->
                                Condition = maps:get(Watched, WatchedsMap),
                                io:format(
                                  "    ~p:~n"
                                  "        ~p~n",
                                  [Watched, Condition])
                        end, Watcheds)
              end, WatcherList);
        _ ->
            ok
    end,

    case khepri_adv:get_many(StoreId, [?KHEPRI_WILDCARD_STAR_STAR], Options) of
        {ok, Result} ->
            io:format("~n\033[1;32m== TREE ==\033[0m~n~n●~n", []),
            Tree = khepri_utils:flat_struct_to_tree(Result),
            khepri_utils:display_tree(Tree);
        _ ->
            ok
    end,
    ok.
