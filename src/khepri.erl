%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2021-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

%% @doc Khepri database API.
%%
%% This module exposes the database API to manipulate data.
%%
%% The API is mainly made of the functions used to perform simple direct
%% atomic operations and queries on the database. In addition to that, {@link
%% transaction/1} are the starting point to run transaction functions. However
%% the API to use inside transaction functions is provided by {@link
%% khepri_tx}.
%%
%% This module also provides functions to start and stop (in the future) a
%% simple unclustered Khepri store. For more advanced setup and clustering,
%% see {@link khepri_cluster}.
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
%% When a store is started, a store ID {@link store_id/0} is returned. This
%% store ID is then used by the rest of this module's API. The returned store
%% ID currently corresponds exactly to the Ra cluster name. Currently, it must
%% be an atom; other types are unsupported.
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
-include("src/khepri_fun.hrl").
-include("src/internal.hrl").

-export([
         %% Functions to start & stop (in the future) a Khepri store; for more
         %% advanced functions, including clustering, see `khepri_cluster'.
         start/0,
         start/1,
         start/3,
         reset/2,
         get_store_ids/0,

         %% Simple direct atomic operations & queries.
         put/2, put/3, put/4, put/5,
         create/2, create/3, create/4, create/5,
         update/2, update/3, update/4, update/5,
         compare_and_swap/3, compare_and_swap/4, compare_and_swap/5,
         compare_and_swap/6,

         clear_payload/1, clear_payload/2, clear_payload/3, clear_payload/4,
         delete/1, delete/2, delete/3,

         exists/1, exists/2, exists/3,
         get/1, get/2, get/3,
         get_node_props/1, get_node_props/2, get_node_props/3,
         has_data/1, has_data/2, has_data/3,
         get_data/1, get_data/2, get_data/3,
         get_data_or/2, get_data_or/3, get_data_or/4,
         has_sproc/1, has_sproc/2, has_sproc/3,
         run_sproc/2, run_sproc/3, run_sproc/4,
         register_trigger/3, register_trigger/4, register_trigger/5,

         list/1, list/2, list/3,
         find/2, find/3, find/4,

         clear_store/0, clear_store/1, clear_store/2,

         %% Transactions; `khepri_tx' provides the API to use inside
         %% transaction functions.
         transaction/1, transaction/2, transaction/3, transaction/4,

         info/0,
         info/1]).

-compile({no_auto_import, [get/2, put/2, erase/1]}).

%% FIXME: Dialyzer complains about several functions with "optional" arguments
%% (but not all). I believe the specs are correct, but can't figure out how to
%% please Dialyzer. So for now, let's disable this specific check for the
%% problematic functions.
-if(?OTP_RELEASE >= 24).
-dialyzer({no_underspecs, [start/1, start/3,

                           put/2, put/3,
                           create/2, create/3,
                           update/2, update/3,
                           compare_and_swap/3, compare_and_swap/4,
                           exists/2,
                           has_data/2,
                           get_data/2,
                           get_data_or/3,
                           has_sproc/2,
                           run_sproc/3,
                           transaction/2, transaction/3]}).
-endif.

%% FIXME: The code currently expects that the Ra cluster name is an atom.
%% However, Ra accepts binaries and strings as well. We should probably fix
%% that at some point.
-type store_id() :: atom(). % ra:cluster_name().
%% ID of a Khepri store.
%%
%% This is the same as the Ra cluster name hosting the Khepri store.

-type error(Type) :: {error, Type}.
%% Return value of a failed command or query.

-type data() :: any().
%% Data stored in a node's payload.

-type payload_version() :: pos_integer().
%% Number of changes made to the payload of a node.
%%
%% The payload version starts at 1 when a node is created. It is increased by 1
%% each time the payload is added, modified or removed.

-type child_list_version() :: pos_integer().
%% Number of changes made to the list of child nodes of a node (child nodes
%% added or removed).
%%
%% The child list version starts at 1 when a node is created. It is increased
%% by 1 each time a child is added or removed. Changes made to existing nodes
%% are not reflected in this version.

-type child_list_length() :: non_neg_integer().
%% Number of direct child nodes under a tree node.

-type node_props() ::
    #{data => data(),
      sproc => khepri_fun:standalone_fun(),
      payload_version => payload_version(),
      child_list_version => child_list_version(),
      child_list_length => child_list_length(),
      child_nodes => #{khepri_path:node_id() => node_props()}}.
%% Structure used to return properties, payload and child nodes for a specific
%% node.
%%
%% <ul>
%% <li>Payload version, child list version, and child list count are always
%% included in the structure. The reason the type spec does not make them
%% mandatory is for {@link khepri_utils:flat_struct_to_tree/1} which may
%% construct fake node props without them.</li>
%% <li>Data is only included if there is data in the node's payload. Absence of
%% data is represented as no `data' entry in this structure.</li>
%% <li>Child nodes are only included if requested.</li>
%% </ul>

-type node_props_map() :: #{khepri_path:native_path() => node_props()}.
%% Structure used to return a map of nodes and their associated properties,
%% payload and child nodes.
%%
%% This structure is used in the return value of all commands and queries.

-type result() :: khepri:ok(node_props_map()) |
                  khepri:error().
%% Return value of a query or synchronous command.

-type keep_while_conds_map() :: #{khepri_path:path() =>
                                  khepri_condition:keep_while()}.
%% Per-node `keep_while' conditions.
%%
%% When a node is put with `keep_while' conditions, this node will be kept in
%% the database while each condition remains true for their associated path.
%%
%% Example:
%% ```
%% khepri:put(
%%   StoreId,
%%   [foo],
%%   Payload,
%%   #{keep_while => #{
%%     %% The node `[foo]' will be removed as soon as `[bar]' is removed
%%     %% because the condition associated with `[bar]' will not be true
%%     %% anymore.
%%     [bar] => #if_node_exists{exists = true}
%%   }}
%% ).
%% '''

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

-type command_options() :: #{async => async_option()}.
%% Options used in commands.
%%
%% Commands are {@link put/5}, {@link delete/3} and read-write {@link
%% transaction/4}.
%%
%% <ul>
%% <li>`async' indicates the synchronous or asynchronous nature of the
%% command; see {@link async_option()}.</li>
%% </ul>

-type query_options() :: #{expect_specific_node => boolean(),
                           include_child_names => boolean(),
                           favor => favor_option()}.
%% Options used in queries.
%%
%% <ul>
%% <li>`expect_specific_node' indicates if the path is expected to point to a
%% specific tree node or could match many nodes.</li>
%% <li>`include_child_names' indicates if child names should be included in
%% the returned node properties map.</li>
%% <li>`favor' indicates where to put the cursor between freshness of the
%% returned data and low latency of queries; see {@link favor_option()}.</li>
%% </ul>

-type ok(Type) :: {ok, Type}.
%% The result of a function after a successful call, wrapped in an "ok" tuple.

-type error() :: error(any()).
%% The error tuple returned by a function after a failure.

-export_type([store_id/0,
              ok/1,
              error/0,

              data/0,
              payload_version/0,
              child_list_version/0,
              child_list_length/0,
              node_props/0,
              node_props_map/0,
              result/0,
              keep_while_conds_map/0,
              trigger_id/0,

              async_option/0,
              favor_option/0,
              command_options/0,
              query_options/0]).

%% -------------------------------------------------------------------
%% Service management.
%% -------------------------------------------------------------------

-spec start() -> Ret when
      Ret :: ok(StoreId) | error(),
      StoreId :: store_id().
%% @doc Starts a store on the default Ra system.
%%
%% The store uses the default Ra cluster name and cluster friendly name.
%%
%% @see khepri_cluster:start/0.

start() ->
    khepri_cluster:start().

-spec start(RaSystem) -> Ret when
      RaSystem :: atom(),
      Ret :: ok(StoreId) | error(),
      StoreId :: store_id().
%% @doc Starts a store on the specified Ra system.
%%
%% The store uses the default Ra cluster name and cluster friendly name.
%%
%% @param RaSystem the name of the Ra system.
%%
%% @see khepri_cluster:start/1.

start(RaSystem) ->
    khepri_cluster:start(RaSystem).

-spec start(RaSystem, ClusterName, FriendlyName) -> Ret when
      RaSystem :: atom(),
      ClusterName :: ra:cluster_name(),
      FriendlyName :: string(),
      Ret :: ok(StoreId) | error(),
      StoreId :: store_id().
%% @doc Starts a store on the specified Ra system.
%%
%% @param RaSystem the name of the Ra system.
%% @param ClusterName the name of the Ra cluster.
%% @param FriendlyName the friendly name of the Ra cluster.
%%
%% @see khepri_cluster:start/3.

start(RaSystem, ClusterName, FriendlyName) ->
    khepri_cluster:start(RaSystem, ClusterName, FriendlyName).

-spec reset(RaSystem, ClusterName) -> Ret when
      RaSystem :: atom(),
      ClusterName :: ra:cluster_name(),
      Ret :: ok | error() | {badrpc, any()}.
%% @doc Resets the store on this Erlang node.
%%
%% It does that by force-deleting the Ra local server.
%%
%% @param RaSystem the name of the Ra system.
%% @param ClusterName the name of the Ra cluster.
%%
%% @see khepri_cluster:reset/2.

reset(RaSystem, ClusterName) ->
    khepri_cluster:reset(RaSystem, ClusterName).

-spec get_store_ids() -> [StoreId] when
      StoreId :: store_id().
%% @doc Returns the list of running stores.
%%
%% @see khepri_cluster:get_store_ids/0.

get_store_ids() ->
    khepri_cluster:get_store_ids().

%% -------------------------------------------------------------------
%% Data manipulation.
%% -------------------------------------------------------------------

-spec put(PathPattern, Data) -> Result when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Creates or modifies a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `put(StoreId, PathPattern,
%% Data)' with the default store ID.
%%
%% @see put/3.

put(PathPattern, Data) ->
    put(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Data).

-spec put(StoreId, PathPattern, Data) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Creates or modifies a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `put(StoreId, PathPattern,
%% Data, #{}, #{})'.
%%
%% @see put/5.

put(StoreId, PathPattern, Data) ->
    put(StoreId, PathPattern, Data, #{}, #{}).

-spec put(StoreId, PathPattern, Data, Extra | Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Creates or modifies a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `put(StoreId, PathPattern,
%% Data, Extra, Options)' with an empty `Extra' or `Options'.
%%
%% @see put/5.

put(StoreId, PathPattern, Data, #{keep_while := _} = Extra) ->
    put(StoreId, PathPattern, Data, Extra, #{});
put(StoreId, PathPattern, Data, Options) ->
    put(StoreId, PathPattern, Data, #{}, Options).

-spec put(StoreId, PathPattern, Data, Extra, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Creates or modifies a specific tree node in the tree structure.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The path or path pattern must target a specific tree node. In other words,
%% updating many nodes with the same payload is denied. That fact is checked
%% before the node is looked up: so if a condition in the path could
%% potentially match several nodes, an error is returned, even though only one
%% node would match at the time.
%%
%% When using a simple path (i.e. without conditions), if the target node does
%% not exist, it is created using the given payload. If the target node exists,
%% it is updated with the given payload and its payload version is increased by
%% one. Missing parent nodes are created on the way.
%%
%% When using a path pattern, the behavior is the same. However if a condition
%% in the path pattern is not met, an error is returned and the tree structure
%% is not modified.
%%
%% If the target node is modified, the returned structure in the "ok" tuple
%% will have a single key corresponding to the resolved path of the target
%% node. The path will be the same as the argument if it was a simple path, or
%% the final path after conditions were applied if it was a path pattern. That
%% key will point to a map containing the properties and payload (if any) of
%% the node before the modification.
%%
%% If the target node is created, the returned structure in the "ok" tuple will
%% have a single key corresponding to the path of the target node. That key
%% will point to an empty map, indicating there was no existing node (i.e.
%% there was no properties or payload to return).
%%
%% The payload must be one of the following form:
%% <ul>
%% <li>An explicit absense of payload ({@link khepri_payload:no_payload()}),
%% using the marker returned by {@link khepri_payload:none/0}, meaning there
%% will be no payload attached to the node and the existing payload will be
%% discarded if any</li>
%% <li>An anonymous function; it will be considered a stored procedure and will
%% be wrapped in a {@link khepri_payload:sproc()} record</li>
%% <li>Any other term; it will be wrapped in a {@link khepri_payload:data()}
%% record</li>
%% </ul>
%%
%% It is possible to wrap the payload in its internal structure explicitly
%% using the {@link khepri_payload} module directly.
%%
%% The `Extra' map may specify put-specific options:
%% <ul>
%% <li>`keep_while': `keep_while' conditions to tie the life of the inserted
%% node to conditions on other nodes; see {@link
%% keep_while_conds_map()}.</li>
%% </ul>
%%
%% The `Options' map may specify command-level options; see {@link
%% command_options()}.
%%
%% Example:
%% ```
%% %% Insert a node at `/:foo/:bar', overwriting the previous value.
%% Result = khepri:put(ra_cluster_name, [foo, bar], new_value),
%%
%% %% Here is the content of `Result'.
%% {ok, #{[foo, bar] => #{data => old_value,
%%                        payload_version => 1,
%%                        child_list_version => 1,
%%                        child_list_length => 0}}} = Result.
%% '''
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Extra extra options such as `keep_while' conditions.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous put, an `{ok, Result}' tuple with a
%% map with one entry, or an `{error, Reason}' tuple; in the case of an
%% asynchronous put, always `ok' (the actual return value may be sent by a
%% message if a correlation ID was specified).

put(StoreId, PathPattern, Data, Extra, Options) ->
    do_put(StoreId, PathPattern, Data, Extra, Options).

-spec create(PathPattern, Data) -> Result when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Creates a specific tree node in the tree structure only if it does not
%% exist.
%%
%% Calling this function is the same as calling `create(StoreId, PathPattern,
%% Data)' with the default store ID.
%%
%% @see create/3.

create(PathPattern, Data) ->
    create(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Data).

-spec create(StoreId, PathPattern, Data) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Creates a specific tree node in the tree structure only if it does not
%% exist.
%%
%% Calling this function is the same as calling `create(StoreId, PathPattern,
%% Data, #{}, #{})'.
%%
%% @see create/5.

create(StoreId, PathPattern, Data) ->
    create(StoreId, PathPattern, Data, #{}, #{}).

-spec create(StoreId, PathPattern, Data, Extra | Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Creates a specific tree node in the tree structure only if it does not
%% exist.
%%
%% Calling this function is the same as calling `create(StoreId, PathPattern,
%% Data, Extra, Options)' with an empty `Extra' or `Options'.
%%
%% @see create/5.

create(StoreId, PathPattern, Data, #{keep_while := _} = Extra) ->
    create(StoreId, PathPattern, Data, Extra, #{});
create(StoreId, PathPattern, Data, Options) ->
    create(StoreId, PathPattern, Data, #{}, Options).

-spec create(StoreId, PathPattern, Data, Extra, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Creates a specific tree node in the tree structure only if it does not
%% exist.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_node_exists{exists = false}' condition on its last component.
%% Otherwise, the behavior is that of {@link put/5}.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Extra extra options such as `keep_while' conditions.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous put, an `{ok, Result}' tuple with a
%% map with one entry, or an `{error, Reason}' tuple; in the case of an
%% asynchronous put, always `ok' (the actual return value may be sent by a
%% message if a correlation ID was specified).
%%
%% @see put/5.

create(StoreId, PathPattern, Data, Extra, Options) ->
    PathPattern1 = khepri_path:from_string(PathPattern),
    PathPattern2 = khepri_path:combine_with_conditions(
                     PathPattern1, [#if_node_exists{exists = false}]),
    do_put(StoreId, PathPattern2, Data, Extra, Options).

-spec update(PathPattern, Data) -> Result when
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists.
%%
%% Calling this function is the same as calling `update(StoreId, PathPattern,
%% Data)' with the default store ID.
%%
%% @see update/3.

update(PathPattern, Data) ->
    update(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Data).

-spec update(StoreId, PathPattern, Data) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists.
%%
%% Calling this function is the same as calling `update(StoreId, PathPattern,
%% Data, #{}, #{})'.
%%
%% @see update/5.

update(StoreId, PathPattern, Data) ->
    update(StoreId, PathPattern, Data, #{}, #{}).

-spec update(StoreId, PathPattern, Data, Extra | Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists.
%%
%% Calling this function is the same as calling `update(StoreId, PathPattern,
%% Data, Extra, Options)' with an empty `Extra' or `Options'.
%%
%% @see update/5.

update(StoreId, PathPattern, Data, #{keep_while := _} = Extra) ->
    update(StoreId, PathPattern, Data, Extra, #{});
update(StoreId, PathPattern, Data, Options) ->
    update(StoreId, PathPattern, Data, #{}, Options).

-spec update(StoreId, PathPattern, Data, Extra, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_node_exists{exists = true}' condition on its last component.
%% Otherwise, the behavior is that of {@link put/5}.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Extra extra options such as `keep_while' conditions.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous put, an `{ok, Result}' tuple with a
%% map with one entry, or an `{error, Reason}' tuple; in the case of an
%% asynchronous put, always `ok' (the actual return value may be sent by a
%% message if a correlation ID was specified).
%%
%% @see put/5.

update(StoreId, PathPattern, Data, Extra, Options) ->
    PathPattern1 = khepri_path:from_string(PathPattern),
    PathPattern2 = khepri_path:combine_with_conditions(
                     PathPattern1, [#if_node_exists{exists = true}]),
    do_put(StoreId, PathPattern2, Data, Extra, Options).

-spec compare_and_swap(PathPattern, DataPattern, Data) -> Result when
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists and its data matches the given `DataPattern'.
%%
%% Calling this function is the same as calling `compare_and_swap(StoreId,
%% PathPattern, DataPattern, Data)' with the default store ID.
%%
%% @see compare_and_swap/4.

compare_and_swap(PathPattern, DataPattern, Data) ->
    compare_and_swap(?DEFAULT_RA_CLUSTER_NAME, PathPattern, DataPattern, Data).

-spec compare_and_swap(StoreId, PathPattern, DataPattern, Data) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Result :: result().
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists and its data matches the given `DataPattern'.
%%
%% Calling this function is the same as calling `compare_and_swap(StoreId,
%% PathPattern, DataPattern, Data, #{}, #{})'.
%%
%% @see compare_and_swap/6.

compare_and_swap(StoreId, PathPattern, DataPattern, Data) ->
    compare_and_swap(StoreId, PathPattern, DataPattern, Data, #{}, #{}).

-spec compare_and_swap(
        StoreId, PathPattern, DataPattern, Data, Extra | Options) ->
    Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists and its data matches the given `DataPattern'.
%%
%% Calling this function is the same as calling `compare_and_swap(StoreId,
%% PathPattern, DataPattern, Data, Extra, Options)' with an empty `Extra' or
%% `Options'.
%%
%% @see compare_and_swap/6.

compare_and_swap(
  StoreId, PathPattern, DataPattern, Data, #{keep_while := _} = Extra) ->
    compare_and_swap(StoreId, PathPattern, DataPattern, Data, Extra, #{});
compare_and_swap(StoreId, PathPattern, DataPattern, Data, Options) ->
    compare_and_swap(StoreId, PathPattern, DataPattern, Data, #{}, Options).

-spec compare_and_swap(
        StoreId, PathPattern, DataPattern, Data, Extra, Options) ->
    Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      DataPattern :: ets:match_pattern(),
      Data :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Updates a specific tree node in the tree structure only if it already
%% exists and its data matches the given `DataPattern'.
%%
%% Internally, the `PathPattern' is modified to include an
%% `#if_data_matches{pattern = DataPattern}' condition on its last component.
%% Otherwise, the behavior is that of {@link put/5}.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the node to create or
%%        modify.
%% @param Data the Erlang term or function to store, or a {@link
%%        khepri_payload:payload()} structure.
%% @param Extra extra options such as `keep_while' conditions.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous put, an `{ok, Result}' tuple with a
%% map with one entry, or an `{error, Reason}' tuple; in the case of an
%% asynchronous put, always `ok' (the actual return value may be sent by a
%% message if a correlation ID was specified).
%%
%% @see put/5.

compare_and_swap(StoreId, PathPattern, DataPattern, Data, Extra, Options) ->
    PathPattern1 = khepri_path:from_string(PathPattern),
    PathPattern2 = khepri_path:combine_with_conditions(
                     PathPattern1, [#if_data_matches{pattern = DataPattern}]),
    do_put(StoreId, PathPattern2, Data, Extra, Options).

-spec do_put(StoreId, PathPattern, Payload, Extra, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Payload :: khepri_payload:payload() | data() | fun(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Prepares the payload and calls {@link khepri_machine:put/5}.
%%
%% @private

do_put(StoreId, PathPattern, Payload, Extra, Options) ->
    Payload1 = khepri_payload:wrap(Payload),
    khepri_machine:put(StoreId, PathPattern, Payload1, Extra, Options).

-spec clear_payload(PathPattern) -> Result when
      PathPattern :: khepri_path:pattern(),
      Result :: result().
%% @doc Clears the payload of a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `clear_payload(StoreId,
%% PathPattern)' with the default store ID.
%%
%% @see clear_payload/2.

clear_payload(PathPattern) ->
    clear_payload(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec clear_payload(StoreId, PathPattern) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Result :: result().
%% @doc Clears the payload of a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `clear_payload(StoreId,
%% PathPattern, #{}, #{})'.
%%
%% @see clear_payload/4.

clear_payload(StoreId, PathPattern) ->
    clear_payload(StoreId, PathPattern, #{}, #{}).

-spec clear_payload(StoreId, PathPattern, Extra | Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Clears the payload of a specific tree node in the tree structure.
%%
%% Calling this function is the same as calling `clear_payload(StoreId,
%% PathPattern, Extra, Options)' with an empty `Extra' or `Options'.
%%
%% @see clear_payload/4.

clear_payload(StoreId, PathPattern, #{keep_while := _} = Extra) ->
    clear_payload(StoreId, PathPattern, Extra, #{});
clear_payload(StoreId, PathPattern, Options) ->
    clear_payload(StoreId, PathPattern, #{}, Options).

-spec clear_payload(StoreId, PathPattern, Extra, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Extra :: #{keep_while => keep_while_conds_map()},
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Clears the payload of a specific tree node in the tree structure.
%%
%% In other words, the payload is set to {@link khepri_payload:no_payload()}.
%% Otherwise, the behavior is that of {@link put/5}.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the node to create or
%%        modify.
%% @param Extra extra options such as `keep_while' conditions.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous put, an `{ok, Result}' tuple with a
%% map with one entry, or an `{error, Reason}' tuple; in the case of an
%% asynchronous put, always `ok' (the actual return value may be sent by a
%% message if a correlation ID was specified).
%%
%% @see put/5.

clear_payload(StoreId, PathPattern, Extra, Options) ->
    khepri_machine:put(
      StoreId, PathPattern, khepri_payload:none(), Extra, Options).

-spec delete(PathPattern) -> Result when
      PathPattern :: khepri_path:pattern(),
      Result :: result().
%% @doc Deletes all tree nodes matching the path pattern.
%%
%% Calling this function is the same as calling `delete(StoreId, PathPattern)'
%% with the default store ID.
%%
%% @see delete/2.

delete(PathPattern) ->
    delete(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec delete
(StoreId, PathPattern) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Result :: result();
(PathPattern, Options) -> Result when
      PathPattern :: khepri_path:pattern(),
      Options :: command_options(),
      Result :: result().

%% @doc Deletes all tree nodes matching the path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`delete(StoreId, PathPattern)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, #{})'.</li>
%% <li>`delete(PathPattern, Options)'. Calling it is the same as calling
%% `delete(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see delete/3.

delete(StoreId, PathPattern) when is_atom(StoreId) ->
    delete(StoreId, PathPattern, #{});
delete(PathPattern, Options) when is_map(Options) ->
    delete(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec delete(StoreId, PathPattern, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: command_options(),
      Result :: result() | NoRetIfAsync,
      NoRetIfAsync :: ok.
%% @doc Deletes all tree nodes matching the path pattern.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The returned structure in the "ok" tuple will have a key corresponding to
%% the path for each deleted node. Each key will point to a map containing the
%% properties and payload of that deleted node.
%%
%% Example:
%% ```
%% %% Delete the node at `/:foo/:bar'.
%% Result = khepri:delete(ra_cluster_name, [foo, bar]),
%%
%% %% Here is the content of `Result'.
%% {ok, #{[foo, bar] => #{data => new_value,
%%                        payload_version => 2,
%%                        child_list_version => 1,
%%                        child_list_length => 0}}} = Result.
%% '''
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to delete.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous delete, an `{ok, Result}' tuple with
%% a map with zero, one or more entries, or an `{error, Reason}' tuple; in the
%% case of an asynchronous put, always `ok' (the actual return value may be
%% sent by a message if a correlation ID was specified).

delete(StoreId, PathPattern, Options) ->
    khepri_machine:delete(StoreId, PathPattern, Options).

-spec exists(PathPattern) -> Exists when
      PathPattern :: khepri_path:pattern(),
      Exists :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path exists,
%% otherwise `false'.
%%
%% Calling this function is the same as calling `exists(StoreId, PathPattern)'
%% with the default store ID.
%%
%% @see exists/2.

exists(PathPattern) ->
    exists(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec exists
(StoreId, PathPattern) -> Exists when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Exists :: boolean();
(PathPattern, Options) -> Exists when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Exists :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path exists,
%% otherwise `false'.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`exists(StoreId, PathPattern)'. Calling it is the same as calling
%% `exists(StoreId, PathPattern, #{})'.</li>
%% <li>`exists(PathPattern, Options)'. Calling it is the same as calling
%% `exists(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see exists/3.

exists(StoreId, PathPattern) when is_atom(StoreId) ->
    exists(StoreId, PathPattern, #{});
exists(PathPattern, Options) when is_map(Options) ->
    exists(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec exists(StoreId, PathPattern, Options) -> Exists when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Exists :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path exists,
%% otherwise `false'.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if tree the node exists, `false' if it does not exist or if
%% there was any error.
%%
%% @see get/3.

exists(StoreId, PathPattern, Options) ->
    Options1 = Options#{expect_specific_node => true},
    case get(StoreId, PathPattern, Options1) of
        {ok, _} -> true;
        _       -> false
    end.

-spec get(PathPattern) -> Result when
      PathPattern :: khepri_path:pattern(),
      Result :: result().
%% @doc Returns all tree nodes matching the path pattern.
%%
%% Calling this function is the same as calling `get(StoreId, PathPattern)'
%% with the default store ID.
%%
%% @see get/2.

get(PathPattern) ->
    get(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec get
(StoreId, PathPattern) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Result :: result();
(PathPattern, Options) -> Result when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Result :: result().
%% @doc Returns all tree nodes matching the path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get(StoreId, PathPattern)'. Calling it is the same as calling
%% `get(StoreId, PathPattern, #{})'.</li>
%% <li>`get(PathPattern, Options)'. Calling it is the same as calling
%% `get(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see get/3.

get(StoreId, PathPattern) when is_atom(StoreId) ->
    get(StoreId, PathPattern, #{});
get(PathPattern, Options) when is_map(Options) ->
    get(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec get(StoreId, PathPattern, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Result :: result().
%% @doc Returns all tree nodes matching the path pattern.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The returned structure in the "ok" tuple will have a key corresponding to
%% the path for each node matching the path pattern. Each key will point to a
%% map containing the properties and payload of that matching node.
%%
%% Example:
%% ```
%% %% Query the node at `/:foo/:bar'.
%% Result = khepri:get(ra_cluster_name, [foo, bar]),
%%
%% %% Here is the content of `Result'.
%% {ok, #{[foo, bar] => #{data => new_value,
%%                        payload_version => 2,
%%                        child_list_version => 1,
%%                        child_list_length => 0}}} = Result.
%% '''
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to get.
%% @param Options query options such as `favor'.
%%
%% @returns an `{ok, Result}' tuple with a map with zero, one or more entries,
%% or an `{error, Reason}' tuple.

get(StoreId, PathPattern, Options) ->
    khepri_machine:get(StoreId, PathPattern, Options).

-spec get_node_props(PathPattern) -> NodeProps when
      PathPattern :: khepri_path:pattern(),
      NodeProps :: node_props().
%% @doc Returns the tree node properties associated with the given node path.
%%
%% Calling this function is the same as calling `get_node_props(StoreId,
%% PathPattern)' with the default store ID.
%%
%% @see get_node_props/2.

get_node_props(PathPattern) ->
    get_node_props(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec get_node_props
(StoreId, PathPattern) -> NodeProps when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      NodeProps :: node_props();
(PathPattern, Options) -> NodeProps when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      NodeProps :: node_props().
%% @doc Returns the tree node properties associated with the given node path.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_node_props(StoreId, PathPattern)'. Calling it is the same as
%% calling `get_node_props(StoreId, PathPattern, #{})'.</li>
%% <li>`get_node_props(PathPattern, Options)'. Calling it is the same as
%% calling `get_node_props(StoreId, PathPattern, Options)' with the default
%% store ID.</li>
%% </ul>
%%
%% @see get_node_props/3.

get_node_props(StoreId, PathPattern) when is_atom(StoreId) ->
    get_node_props(StoreId, PathPattern, #{});
get_node_props(PathPattern, Options) when is_map(Options) ->
    get_node_props(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec get_node_props(StoreId, PathPattern, Options) -> NodeProps when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      NodeProps :: node_props().
%% @doc Returns the tree node properties associated with the given node path.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% Unlike {@link get/3}, this function is optimistic and returns the
%% properties directly. If the node does not exist or if there are any errors,
%% an exception is raised.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns the tree node properties if the node exists, or throws an
%% exception otherwise.
%%
%% @see get/3.

get_node_props(StoreId, PathPattern, Options) ->
    Options1 = Options#{expect_specific_node => true},
    case get(StoreId, PathPattern, Options1) of
        {ok, Result} ->
            [{_Path, NodeProps}] = maps:to_list(Result),
            NodeProps;
        Error ->
            throw(Error)
    end.

-spec has_data(PathPattern) -> HasData when
      PathPattern :: khepri_path:pattern(),
      HasData :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path has data,
%% otherwise `false'.
%%
%% Calling this function is the same as calling `has_data(StoreId,
%% PathPattern)' with the default store ID.
%%
%% @see has_data/2.

has_data(PathPattern) ->
    has_data(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec has_data
(StoreId, PathPattern) -> HasData when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      HasData :: boolean();
(PathPattern, Options) -> HasData when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      HasData :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path has data,
%% otherwise `false'.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`has_data(StoreId, PathPattern)'. Calling it is the same as calling
%% `has_data(StoreId, PathPattern, #{})'.</li>
%% <li>`has_data(PathPattern, Options)'. Calling it is the same as calling
%% `has_data(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see has_data/3.

has_data(StoreId, PathPattern) when is_atom(StoreId) ->
    has_data(StoreId, PathPattern, #{});
has_data(PathPattern, Options) when is_map(Options) ->
    has_data(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec has_data(StoreId, PathPattern, Options) -> HasData when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      HasData :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path has data,
%% otherwise `false'.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if tree the node holds data, `false' if it does not exist,
%% has no payload, holds a stored procedure or if there was any error.
%%
%% @see get/3.

has_data(StoreId, PathPattern, Options) ->
    try
        NodeProps = get_node_props(StoreId, PathPattern, Options),
        maps:is_key(data, NodeProps)
    catch
        throw:{error, _} ->
            false
    end.

-spec get_data(PathPattern) -> Data when
      PathPattern :: khepri_path:pattern(),
      Data :: data().
%% @doc Returns the data associated with the given node path.
%%
%% Calling this function is the same as calling `get_data(StoreId,
%% PathPattern)' with the default store ID.
%%
%% @see get_data/2.

get_data(PathPattern) ->
    get_data(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec get_data
(StoreId, PathPattern) -> Data when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Data :: data();
(PathPattern, Options) -> Data when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Data :: data().
%% @doc Returns the data associated with the given node path.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_data(StoreId, PathPattern)'. Calling it is the same as calling
%% `get_data(StoreId, PathPattern, #{})'.</li>
%% <li>`get_data(PathPattern, Options)'. Calling it is the same as calling
%% `get_data(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see get_data/3.

get_data(StoreId, PathPattern) when is_atom(StoreId) ->
    get_data(StoreId, PathPattern, #{});
get_data(PathPattern, Options) when is_map(Options) ->
    get_data(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec get_data(StoreId, PathPattern, Options) -> Data when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Data :: data().
%% @doc Returns the data associated with the given node path.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% Unlike {@link get/3}, this function is optimistic and returns the data
%% directly. An exception is raised for the following reasons:
%% <ul>
%% <li>the node does not exist</li>
%% <li>the node has no payload</li>
%% <li>the node holds a stored procedure</li>
%% </ul>
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns the data if the node has a data payload, or throws an exception if
%% it does not exist, has no payload or holds a stored procedure.
%%
%% @see get/3.

get_data(StoreId, PathPattern, Options) ->
    NodeProps = get_node_props(StoreId, PathPattern, Options),
    case NodeProps of
        #{data := Data} -> Data;
        _               -> throw({error, {no_data, NodeProps}})
    end.

-spec get_data_or(PathPattern, Default) -> Data when
      PathPattern :: khepri_path:pattern(),
      Default :: data(),
      Data :: data().
%% @doc Returns the data associated with the given node path, or `Default' if
%% there is no data.
%%
%% Calling this function is the same as calling `get_data_or(StoreId,
%% PathPattern, Default)' with the default store ID.
%%
%% @see get_data_or/3.

get_data_or(PathPattern, Default) ->
    get_data_or(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Default).

-spec get_data_or
(StoreId, PathPattern, Default) -> Data when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: data(),
      Data :: data();
(PathPattern, Options, Default) -> Data when
      PathPattern :: khepri_path:pattern(),
      Default :: data(),
      Options :: query_options(),
      Data :: data().
%% @doc Returns the data associated with the given node path, or `Default' if
%% there is no data.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`get_data_or(StoreId, PathPattern, Default)'. Calling it is the same as
%% calling `get_data_or(StoreId, PathPattern, Default, #{})'.</li>
%% <li>`get_data_or(PathPattern, Default, Options)'. Calling it is the same as
%% calling `get_data_or(StoreId, PathPattern, Default, Options)' with the
%% default store ID.</li>
%% </ul>
%%
%% @see get_data_or/4.

get_data_or(StoreId, PathPattern, Default) when is_atom(StoreId) ->
    get_data_or(StoreId, PathPattern, Default, #{});
get_data_or(PathPattern, Default, Options) when is_map(Options) ->
    get_data_or(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Default, Options).

-spec get_data_or(StoreId, PathPattern, Default, Options) -> Data when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Default :: data(),
      Options :: query_options(),
      Data :: data().
%% @doc Returns the data associated with the given node path, or `Default' if
%% there is no data.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% `Default' is returned if one of the following reasons is met:
%% <ul>
%% <li>the node does not exist</li>
%% <li>the node has no payload</li>
%% <li>the node holds a stored procedure</li>
%% </ul>
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Default the default term to return if there is no data.
%% @param Options query options such as `favor'.
%%
%% @returns the data if the node has a data payload, or `Default' if it does
%% not exist, has no payload or holds a stored procedure.
%%
%% @see get/3.

get_data_or(StoreId, PathPattern, Default, Options) ->
    try
        NodeProps = get_node_props(StoreId, PathPattern, Options),
        case NodeProps of
            #{data := Data} -> Data;
            _               -> Default
        end
    catch
        throw:{error, {node_not_found, _}} ->
            Default
    end.

-spec has_sproc(PathPattern) -> HasStoredProc when
      PathPattern :: khepri_path:pattern(),
      HasStoredProc :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path holds a
%% stored procedure, otherwise `false'.
%%
%% Calling this function is the same as calling `has_sproc(StoreId,
%% PathPattern)' with the default store ID.
%%
%% @see has_sproc/2.

has_sproc(PathPattern) ->
    has_sproc(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec has_sproc
(StoreId, PathPattern) -> HasStoredProc when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      HasStoredProc :: boolean();
(PathPattern, Options) -> HasStoredProc when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      HasStoredProc :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path holds a
%% stored procedure, otherwise `false'.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`has_sproc(StoreId, PathPattern)'. Calling it is the same as calling
%% `has_sproc(StoreId, PathPattern, #{})'.</li>
%% <li>`has_sproc(PathPattern, Options)'. Calling it is the same as calling
%% `has_sproc(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see has_sproc/3.

has_sproc(StoreId, PathPattern) when is_atom(StoreId) ->
    has_sproc(StoreId, PathPattern, #{});
has_sproc(PathPattern, Options) when is_map(Options) ->
    has_sproc(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec has_sproc(StoreId, PathPattern, Options) -> HasStoredProc when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      HasStoredProc :: boolean().
%% @doc Returns `true' if the tree node pointed to by the given path holds a
%% stored procedure, otherwise `false'.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Options query options such as `favor'.
%%
%% @returns `true' if the node holds a stored procedure, `false' if it does
%% not exist, has no payload, holds data or if there was any error.
%%
%% @see get/3.

has_sproc(StoreId, PathPattern, Options) ->
    Options1 = Options#{expect_specific_node => true},
    case get(StoreId, PathPattern, Options1) of
        {ok, Result} ->
            [NodeProps] = maps:values(Result),
            maps:is_key(sproc, NodeProps);
        _ ->
            false
    end.

-spec run_sproc(PathPattern, Args) -> Result when
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Result :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% Calling this function is the same as calling `run_sproc(StoreId,
%% PathPattern, Args)' with the default store ID.
%%
%% @see run_sproc/3.

run_sproc(PathPattern, Args) ->
    run_sproc(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Args).

-spec run_sproc
(StoreId, PathPattern, Args) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Result :: any();
(PathPattern, Args, Options) -> Result when
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Options :: query_options(),
      Result :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`run_sproc(StoreId, PathPattern, Args)'. Calling it is the same as
%% calling `run_sproc(StoreId, PathPattern, Args, #{})'.</li>
%% <li>`run_sproc(PathPattern, Args, Options)'. Calling it is the same as
%% calling `run_sproc(StoreId, PathPattern, Args, Options)' with the default
%% store ID.</li>
%% </ul>
%%
%% @see run_sproc/3.

run_sproc(StoreId, PathPattern, Args) when is_atom(StoreId) ->
    run_sproc(StoreId, PathPattern, Args, #{});
run_sproc(PathPattern, Args, Options) when is_map(Options) ->
    run_sproc(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Args, Options).

-spec run_sproc(StoreId, PathPattern, Args, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Args :: list(),
      Options :: query_options(),
      Result :: any().
%% @doc Runs the stored procedure pointed to by the given path and returns the
%% result.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% The `PathPattern' must point to a specific tree node and can't match
%% multiple nodes.
%%
%% The `Args' list must match the number of arguments expected by the stored
%% procedure.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to check.
%% @param Args the list of args to pass to the stored procedure; its length
%%        must be equal to the stored procedure arity.
%% @param Options query options such as `favor'.
%%
%% @returns the result of the stored procedure execution, or throws an
%% exception if the node does not exist, does not hold a stored procedure or
%% if there was an error.

run_sproc(StoreId, PathPattern, Args, Options) ->
    khepri_machine:run_sproc(StoreId, PathPattern, Args, Options).

-spec register_trigger(TriggerId, EventFilter, StoredProcPath) -> Ret when
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Ret :: ok | error().
%% @doc Registers a trigger.
%%
%% Calling this function is the same as calling `register_trigger(StoreId,
%% TriggerId, EventFilter, StoredProcPath)' with the default store ID.
%%
%% @see register_trigger/4.

register_trigger(TriggerId, EventFilter, StoredProcPath) ->
    register_trigger(
      ?DEFAULT_RA_CLUSTER_NAME, TriggerId, EventFilter, StoredProcPath).

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
      Options :: command_options(),
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
%% EventFilter, StoredProcPath, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see register_trigger/5.

register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath)
  when is_atom(StoreId) ->
    register_trigger(StoreId, TriggerId, EventFilter, StoredProcPath, #{});
register_trigger(TriggerId, EventFilter, StoredProcPath, Options)
  when is_map(Options) ->
    register_trigger(
      ?DEFAULT_RA_CLUSTER_NAME, TriggerId, EventFilter, StoredProcPath,
      Options).

-spec register_trigger(
        StoreId, TriggerId, EventFilter, StoredProcPath, Options) ->
    Ret when
      StoreId :: khepri:store_id(),
      TriggerId :: trigger_id(),
      EventFilter :: khepri_evf:event_filter() |
                     khepri_path:pattern(),
      StoredProcPath :: khepri_path:path(),
      Options :: command_options(),
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
%% @param StoreId the name of the Ra cluster.
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

-spec list(PathPattern) -> Result when
      PathPattern :: khepri_path:pattern(),
      Result :: result().
%% @doc Returns all direct child nodes under the given path.
%%
%% Calling this function is the same as calling `list(StoreId, PathPattern)'
%% with the default store ID.
%%
%% @see list/2.

list(PathPattern) ->
    list(?DEFAULT_RA_CLUSTER_NAME, PathPattern).

-spec list
(StoreId, PathPattern) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Result :: result();
(PathPattern, Options) -> Result when
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Result :: result().
%% @doc Returns all direct child nodes under the given path.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`list(StoreId, PathPattern)'. Calling it is the same as calling
%% `list(StoreId, PathPattern, #{})'.</li>
%% <li>`list(PathPattern, Options)'. Calling it is the same as calling
%% `list(StoreId, PathPattern, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see list/3.

list(StoreId, PathPattern) when is_atom(StoreId) ->
    list(StoreId, PathPattern, #{});
list(PathPattern, Options) when is_map(Options) ->
    list(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Options).

-spec list(StoreId, PathPattern, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Options :: query_options(),
      Result :: result().
%% @doc Returns all direct child nodes under the given path.
%%
%% The `PathPattern' can be provided as native path (a list of node names and
%% conditions) or as a string. See {@link khepri_path:from_string/1}.
%%
%% Internally, an `#if_name_matches{regex = any}' condition is appended to the
%% `PathPattern'. Otherwise, the behavior is that of {@link get/3}.
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path (or path pattern) to the nodes to get.
%% @param Options query options such as `favor'.
%%
%% @returns an `{ok, Result}' tuple with a map with zero, one or more entries,
%% or an `{error, Reason}' tuple.
%%
%% @see get/3.

list(StoreId, PathPattern, Options) ->
    PathPattern1 = khepri_path:from_string(PathPattern),
    PathPattern2 = [?ROOT_NODE | PathPattern1] ++ [?STAR],
    get(StoreId, PathPattern2, Options).

-spec find(PathPattern, Condition) -> Result when
      PathPattern :: khepri_path:pattern(),
      Condition :: khepri_path:pattern_component(),
      Result :: result().
%% @doc Returns all tree nodes matching the path pattern.
%%
%% Calling this function is the same as calling `find(StoreId, PathPattern)'
%% with the default store ID.
%%
%% @see find/3.

find(PathPattern, Condition) ->
    find(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Condition).

-spec find
(StoreId, PathPattern, Condition) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Condition :: khepri_path:pattern_component(),
      Result :: result();
(PathPattern, Condition, Options) -> Result when
      PathPattern :: khepri_path:pattern(),
      Condition :: khepri_path:pattern_component(),
      Options :: query_options(),
      Result :: result().
%% @doc Returns all tree nodes matching the path pattern.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`find(StoreId, PathPattern, Condition)'. Calling it is the same as
%% calling `find(StoreId, PathPattern, Condition, #{})'.</li>
%% <li>`find(PathPattern, Condition, Options)'. Calling it is the same as
%% calling `find(StoreId, PathPattern, Condition, Options)' with the default
%% store ID.</li>
%% </ul>
%%
%% @see find/4.

find(StoreId, PathPattern, Condition) when is_atom(StoreId) ->
    find(StoreId, PathPattern, Condition, #{});
find(PathPattern, Condition, Options) when is_map(Options) ->
    find(?DEFAULT_RA_CLUSTER_NAME, PathPattern, Condition, Options).

-spec find(StoreId, PathPattern, Condition, Options) -> Result when
      StoreId :: store_id(),
      PathPattern :: khepri_path:pattern(),
      Condition :: khepri_path:pattern_component(),
      Options :: query_options(),
      Result :: result().
%% @doc Finds tree nodes under `PathPattern' which match the given `Condition'.
%%
%% The `PathPattern' can be provided as a list of node names and conditions or
%% as a string. See {@link khepri_path:from_string/1}.
%%
%% Nodes are searched deeply under the given `PathPattern', not only among
%% direct child nodes.
%%
%% Example:
%% ```
%% %% Find nodes with data under `/:foo/:bar'.
%% Result = khepri:find(
%%            ra_cluster_name,
%%            [foo, bar],
%%            #if_has_data{has_data = true}),
%%
%% %% Here is the content of `Result'.
%% {ok, #{[foo, bar, baz] => #{data => baz_value,
%%                             payload_version => 2,
%%                             child_list_version => 1,
%%                             child_list_length => 0},
%%        [foo, bar, deep, under, qux] => #{data => qux_value,
%%                                          payload_version => 1,
%%                                          child_list_version => 1,
%%                                          child_list_length => 0}}} = Result.
%% '''
%%
%% @param StoreId the name of the Ra cluster.
%% @param PathPattern the path indicating where to start the search from.
%% @param Condition the condition nodes must match to be part of the result.
%%
%% @returns an `{ok, Result}' tuple with a map with zero, one or more entries,
%% or an `{error, Reason}' tuple.

find(StoreId, PathPattern, Condition, Options) ->
    Condition1 = #if_all{conditions = [?STAR_STAR, Condition]},
    PathPattern1 = khepri_path:from_string(PathPattern),
    PathPattern2 = [?ROOT_NODE | PathPattern1] ++ [Condition1],
    get(StoreId, PathPattern2, Options).

-spec transaction(Fun) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      Ret :: Atomic | Aborted,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort().
%% @doc Runs a transaction and returns its result.
%%
%% Calling this function is the same as calling `transaction(StoreId, Fun)'
%% with the default store ID.
%%
%% @see transaction/2.

transaction(Fun) ->
    transaction(?DEFAULT_RA_CLUSTER_NAME, Fun).

-spec transaction
(StoreId, Fun) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      Ret :: Atomic | Aborted,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort();
(Fun, ReadWriteOrOptions) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      ReadWriteOrOptions :: ReadWrite | Options,
      ReadWrite :: ro | rw | auto,
      Options :: command_options() |
                 query_options(),
      Ret :: Atomic | Aborted | NoRetIfAsync,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort(),
      NoRetIfAsync :: ok.
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
    transaction(?DEFAULT_RA_CLUSTER_NAME, Fun, ReadWriteOrOptions).

-spec transaction
(StoreId, Fun, ReadWrite) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Ret :: Atomic | Aborted,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort();
(StoreId, Fun, Options) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      Options :: command_options() |
                 query_options(),
      Ret :: Atomic | Aborted | NoRetIfAsync,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort(),
      NoRetIfAsync :: ok;
(Fun, ReadWrite, Options) -> Ret when
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Options :: command_options() |
                 query_options(),
      Ret :: Atomic | Aborted | NoRetIfAsync,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort(),
      NoRetIfAsync :: ok.
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
    transaction(
      ?DEFAULT_RA_CLUSTER_NAME, Fun, ReadWrite, Options).

-spec transaction(StoreId, Fun, ReadWrite, Options) -> Ret when
      StoreId :: store_id(),
      Fun :: khepri_tx:tx_fun(),
      ReadWrite :: ro | rw | auto,
      Options :: command_options() |
                 query_options(),
      Ret :: Atomic | Aborted | NoRetIfAsync,
      Atomic :: {atomic, khepri_tx:tx_fun_result()},
      Aborted :: khepri_tx:tx_abort(),
      NoRetIfAsync :: ok.
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
%% The result of `Fun' can be any term. That result is returned in an
%% `{atomic, Result}' tuple if the transaction is synchronous. The result is
%% sent by message if the transaction is asynchronous and a correlation ID was
%% specified.
%%
%% @param StoreId the name of the Ra cluster.
%% @param Fun an arbitrary anonymous function.
%% @param ReadWrite the read/write or read-only nature of the transaction.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous transaction, `{atomic, Result}' where
%% `Result' is the return value of `Fun', or `{aborted, Reason}' if the
%% anonymous function was aborted; in the case of an asynchronous transaction,
%% always `ok' (the actual return value may be sent by a message if a
%% correlation ID was specified).

transaction(StoreId, Fun, ReadWrite, Options) ->
    khepri_machine:transaction(StoreId, Fun, ReadWrite, Options).

-spec clear_store() -> Result when
      Result :: result().
%% @doc Wipes out the entire tree.
%%
%% Calling this function is the same as calling `clear_store(StoreId)' with
%% the default store ID.
%%
%% @see clear_store/1.

clear_store() ->
    clear_store(?DEFAULT_RA_CLUSTER_NAME).

-spec clear_store
(StoreId) -> Result when
      StoreId :: store_id(),
      Result :: result();
(Options) -> Result when
      Options :: command_options(),
      Result :: result().
%% @doc Wipes out the entire tree.
%%
%% This function accepts the following two forms:
%% <ul>
%% <li>`clear_store(StoreId)'. Calling it is the same as calling
%% `clear_store(StoreId, #{})'.</li>
%% <li>`clear_store(Options)'. Calling it is the same as calling
%% `clear_store(StoreId, Options)' with the default store ID.</li>
%% </ul>
%%
%% @see clear_store/2.

clear_store(StoreId) when is_atom(StoreId) ->
    clear_store(StoreId, #{});
clear_store(Options) when is_map(Options) ->
    clear_store(?DEFAULT_RA_CLUSTER_NAME, Options).

-spec clear_store(StoreId, Options) -> Result when
      StoreId :: store_id(),
      Options :: command_options(),
      Result :: result().
%% @doc Wipes out the entire tree.
%%
%% Note that the root node will remain unmodified however.
%%
%% @param StoreId the name of the Ra cluster.
%% @param Options command options such as the command type.
%%
%% @returns in the case of a synchronous delete, an `{ok, Result}' tuple with
%% a map with zero, one or more entries, or an `{error, Reason}' tuple; in the
%% case of an asynchronous put, always `ok' (the actual return value may be
%% sent by a message if a correlation ID was specified).
%%
%% @see delete/3.

clear_store(StoreId, Options) ->
    delete(StoreId, [?STAR], Options).

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
%% @param StoreID the name of the Ra cluster.

info(StoreId) ->
    io:format("~n\033[1;32m== CLUSTER MEMBERS ==\033[0m~n~n", []),
    Nodes = lists:sort(
              [Node || {_, Node} <- khepri_cluster:members(StoreId)]),
    lists:foreach(fun(Node) -> io:format("~ts~n", [Node]) end, Nodes),

    case khepri_machine:get_keep_while_conds_state(StoreId) of
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

    case get(StoreId, [?STAR_STAR]) of
        {ok, Result} ->
            io:format("~n\033[1;32m== TREE ==\033[0m~n~n●~n", []),
            Tree = khepri_utils:flat_struct_to_tree(Result),
            khepri_utils:display_tree(Tree);
        _ ->
            ok
    end,
    ok.
