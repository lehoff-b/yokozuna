%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%%-------------------------------------------------------------------

%% @doc Confirm that the batching and queueing behavior in yz_solrq and
%%      related modules works correctly.
-module(yz_solrq_test).
-export([confirm/0]).
-include("yokozuna.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(INDEX1, <<"solrq_index1">>).
-define(INDEX2, <<"solrq_index2">>).
-define(BUCKET1, {<<"solrq1">>, <<"solrq_bucket1">>}).
-define(BUCKET2, {<<"solrq2">>, <<"solrq_bucket2">>}).

-define(NUM_SOLRQ, 3).
-define(NUM_SOLRQ_HELPERS, 3).
-define(SOLRQ_DELAYMS_MAX, 3000).
-define(SOLRQ_BATCH_MIN, 4).
-define(SOLRQ_BATCH_MAX, 8).
-define(CONFIG,
        [{yokozuna,
          [{enabled, true},
           {num_solrq, ?NUM_SOLRQ},
           {num_solrq_helpers, ?NUM_SOLRQ_HELPERS},
           {solrq_delayms_max, ?SOLRQ_DELAYMS_MAX},
           {solrq_batch_min, ?SOLRQ_BATCH_MIN},
           {solrq_batch_max, ?SOLRQ_BATCH_MAX}]}]).

confirm() ->
    Cluster = yz_rt:prepare_cluster(1, ?CONFIG),
    [PBConn|_] = PBConns = yz_rt:open_pb_conns(Cluster),

    ok = create_indexed_bucket(PBConn, Cluster, ?BUCKET1, ?INDEX1),
    ok = create_indexed_bucket(PBConn, Cluster, ?BUCKET2, ?INDEX2),
    confirm_batching(Cluster, PBConn, ?BUCKET1, ?INDEX1),
    confirm_draining(Cluster, PBConn, ?BUCKET2, ?INDEX2),
    yz_rt:close_pb_conns(PBConns),
    pass.

create_indexed_bucket(PBConn, [Node|_], {BType, _Bucket}, Index) ->
    ok = riakc_pb_socket:create_search_index(PBConn, Index, <<>>, [{n_val, 1}]),
    ok = yz_rt:set_bucket_type_index(Node, BType, Index, 1).

confirm_batching(Cluster, PBConn, BKey, Index) ->
    %% First, put one less than the min batch size and expect that there are no
    %% search results (because the index operations are queued).
    Count = ?SOLRQ_BATCH_MIN - 1,
    Count = put_objects(PBConn, BKey, Count),
    yz_rt:commit(Cluster, Index),
    verify_search_count(PBConn, Index, 0),

    %% Now, put one more and expect that all of them have been indexed (because
    %% the solrq_batch_min has been reached) and therefore show up in search
    %% results.
    1 = put_objects(PBConn, BKey, 1),
    yz_rt:commit(Cluster, Index),
    verify_search_count(PBConn, Index, ?SOLRQ_BATCH_MIN),

    %% Finally, put another batch of one less than solrq_batch_min, but this
    %% time wait until solrq_delayms_max milliseconds (plus a small fudge
    %% factor) have passed and expect that a flush will be triggered and all
    %% objects have been indexed.
    Count = put_objects(PBConn, BKey, Count),
    yz_rt:commit(Cluster, Index),
    verify_search_count(PBConn, Index, ?SOLRQ_BATCH_MIN),
    timer:sleep(?SOLRQ_DELAYMS_MAX + 100),
    verify_search_count(PBConn, Index, ?SOLRQ_BATCH_MIN + Count),
    ok.

confirm_draining(Cluster, PBConn, BKey, Index) ->
    Count = ?SOLRQ_BATCH_MIN - 1,
    Count = put_objects(PBConn, BKey, Count),
    yz_rt:commit(Cluster, Index),
    verify_search_count(PBConn, Index, 0),
    drain_solrqs(hd(Cluster)),
    yz_rt:commit(Cluster, Index),
    verify_search_count(PBConn, Index, Count),
    ok.

-spec put_objects(pid(), bucket(), non_neg_integer()) -> non_neg_integer().
put_objects(PBConn, Bucket, Count) ->
    RandVals = [yz_rt:random_binary(16) || _ <- lists:seq(1, Count)],
    %% Using the same key for every object ensures that they all hash to the
    %% same yz_solrq and the batching is therefore predictable.
    Key = <<"same_key_for_everyone">>,
    Objects = [riakc_obj:new(Bucket, Key, Val, "text/plain") || Val <- RandVals],
    Results = [riakc_pb_socket:put(PBConn, Obj, [return_head]) || Obj <- Objects],
    length(lists:filter(fun({Result, _}) ->
                                ok =:= Result
                        end,
                        Results)).

verify_search_count(PBConn, Index, Count) ->
    {ok, {search_results, _R, _Score, Found}} =
        riakc_pb_socket:search(PBConn, Index, <<"*:*">>),
    ?assertEqual(Count, Found).

drain_solrqs(Node) ->
    rpc:call(Node, yz_solrq_sup, drain, []).