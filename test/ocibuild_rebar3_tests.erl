%%%-------------------------------------------------------------------
-module(ocibuild_rebar3_tests).
-moduledoc "Tests for the rebar3 provider".

-include_lib("eunit/include/eunit.hrl").

%%%===================================================================
%%% File collection tests (using exported function)
%%%===================================================================

collect_release_files_test() ->
    %% Create a mock release directory structure
    TmpDir = create_mock_release(),
    try
        %% Test file collection using the actual exported function
        {ok, Files} = ocibuild_rebar3:collect_release_files(TmpDir),

        %% Should have collected the files we created
        ?assert(length(Files) >= 3),

        %% Check that bin/myapp has executable permissions
        BinFile = lists:keyfind(~"/app/bin/myapp", 1, Files),
        ?assertNotEqual(false, BinFile),
        {_, _, BinMode} = BinFile,
        ?assertEqual(8#755, BinMode band 8#777),

        %% Check that lib file has regular permissions
        LibFile = lists:keyfind(~"/app/lib/myapp-1.0.0/ebin/myapp.beam", 1, Files),
        ?assertNotEqual(false, LibFile),
        {_, _, LibMode} = LibFile,
        ?assertEqual(8#644, LibMode band 8#777)
    after
        %% Cleanup
        cleanup_temp_dir(TmpDir)
    end.

collect_empty_dir_test() ->
    TmpDir = make_temp_dir("ocibuild_empty"),
    try
        {ok, Files} = ocibuild_rebar3:collect_release_files(TmpDir),
        ?assertEqual([], Files)
    after
        cleanup_temp_dir(TmpDir)
    end.

%%%===================================================================
%%% Build image tests (using exported function)
%%%===================================================================

build_scratch_image_test() ->
    Files =
        [
            {~"/app/bin/myapp", ~"#!/bin/sh\necho hello", 8#755},
            {~"/app/lib/myapp.beam", ~"beam_data", 8#644}
        ],

    {ok, Image} = ocibuild_rebar3:build_image(
        ~"scratch", Files, "myapp", ~"/app", #{}, [], #{}
    ),

    %% Verify image structure
    ?assert(is_map(Image)),
    ?assertEqual(1, length(maps:get(layers, Image))),

    %% Verify config
    Config = maps:get(config, Image),
    InnerConfig = maps:get(~"config", Config),
    ?assertEqual(
        [~"/app/bin/myapp", ~"foreground"],
        maps:get(~"Entrypoint", InnerConfig)
    ),
    ?assertEqual(~"/app", maps:get(~"WorkingDir", InnerConfig)).

build_with_env_test() ->
    Files = [{~"/app/test", ~"data", 8#644}],
    EnvMap = #{~"LANG" => ~"C.UTF-8", ~"PORT" => ~"8080"},

    {ok, Image} = ocibuild_rebar3:build_image(
        ~"scratch", Files, "myapp", ~"/app", EnvMap, [], #{}
    ),

    Config = maps:get(config, Image),
    InnerConfig = maps:get(~"config", Config),
    EnvList = maps:get(~"Env", InnerConfig),

    %% Should contain both env vars
    ?assert(lists:any(fun(E) -> binary:match(E, ~"LANG=") =/= nomatch end, EnvList)),
    ?assert(lists:any(fun(E) -> binary:match(E, ~"PORT=") =/= nomatch end, EnvList)).

build_with_exposed_ports_test() ->
    Files = [{~"/app/test", ~"data", 8#644}],

    {ok, Image} = ocibuild_rebar3:build_image(
        ~"scratch", Files, "myapp", ~"/app", #{}, [8080, 443], #{}
    ),

    Config = maps:get(config, Image),
    InnerConfig = maps:get(~"config", Config),
    ExposedPorts = maps:get(~"ExposedPorts", InnerConfig),

    ?assert(maps:is_key(~"8080/tcp", ExposedPorts)),
    ?assert(maps:is_key(~"443/tcp", ExposedPorts)).

build_with_labels_test() ->
    Files = [{~"/app/test", ~"data", 8#644}],
    Labels = #{~"org.opencontainers.image.version" => ~"1.0.0"},

    {ok, Image} = ocibuild_rebar3:build_image(
        ~"scratch", Files, "myapp", ~"/app", #{}, [], Labels
    ),

    Config = maps:get(config, Image),
    InnerConfig = maps:get(~"config", Config),
    ImageLabels = maps:get(~"Labels", InnerConfig),

    ?assertEqual(~"1.0.0", maps:get(~"org.opencontainers.image.version", ImageLabels)).

%%%===================================================================
%%% Tag parsing tests (internal logic test)
%%%===================================================================

parse_tag_simple_test() ->
    ?assertEqual({~"myapp", ~"1.0.0"}, parse_tag(~"myapp:1.0.0")).

parse_tag_no_version_test() ->
    ?assertEqual({~"myapp", ~"latest"}, parse_tag(~"myapp")).

parse_tag_with_path_test() ->
    ?assertEqual({~"myorg/myapp", ~"v1"}, parse_tag(~"myorg/myapp:v1")).

%% Helper to test tag parsing logic (mirrors internal function)
parse_tag(Tag) ->
    case binary:split(Tag, ~":") of
        [Repo, ImageTag] -> {Repo, ImageTag};
        [Repo] -> {Repo, ~"latest"}
    end.

%%%===================================================================
%%% Auth tests (using exported function)
%%%===================================================================

get_auth_empty_test() ->
    %% Clear any existing env vars
    os:unsetenv("OCIBUILD_TOKEN"),
    os:unsetenv("OCIBUILD_USERNAME"),
    os:unsetenv("OCIBUILD_PASSWORD"),

    ?assertEqual(#{}, ocibuild_rebar3:get_auth()).

get_auth_token_test() ->
    os:putenv("OCIBUILD_TOKEN", "mytoken123"),
    try
        Auth = ocibuild_rebar3:get_auth(),
        ?assertEqual(#{token => ~"mytoken123"}, Auth)
    after
        os:unsetenv("OCIBUILD_TOKEN")
    end.

get_auth_username_password_test() ->
    os:unsetenv("OCIBUILD_TOKEN"),
    os:putenv("OCIBUILD_USERNAME", "myuser"),
    os:putenv("OCIBUILD_PASSWORD", "mypass"),
    try
        Auth = ocibuild_rebar3:get_auth(),
        ?assertEqual(#{username => ~"myuser", password => ~"mypass"}, Auth)
    after
        os:unsetenv("OCIBUILD_USERNAME"),
        os:unsetenv("OCIBUILD_PASSWORD")
    end.

%%%===================================================================
%%% Cross-platform helpers
%%%===================================================================

%% @doc Get the system temp directory in a cross-platform way
temp_dir() ->
    case os:type() of
        {win32, _} ->
            case os:getenv("TEMP") of
                false ->
                    case os:getenv("TMP") of
                        false ->
                            "C:\\Temp";
                        TmpDir ->
                            TmpDir
                    end;
                TempDir ->
                    TempDir
            end;
        _ ->
            "/tmp"
    end.

%% @doc Create a unique temporary directory
make_temp_dir(Prefix) ->
    Unique = integer_to_list(erlang:unique_integer([positive])),
    DirName = Prefix ++ "_" ++ Unique,
    TmpDir = filename:join(temp_dir(), DirName),
    ok =
        filelib:ensure_dir(
            filename:join(TmpDir, "placeholder")
        ),
    case file:make_dir(TmpDir) of
        ok ->
            TmpDir;
        {error, eexist} ->
            TmpDir
    end.

%% @doc Recursively delete a directory (cross-platform)
cleanup_temp_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true ->
            {ok, Files} = file:list_dir(Dir),
            lists:foreach(
                fun(File) ->
                    Path = filename:join(Dir, File),
                    case filelib:is_dir(Path) of
                        true ->
                            cleanup_temp_dir(Path);
                        false ->
                            file:delete(Path)
                    end
                end,
                Files
            ),
            file:del_dir(Dir);
        false ->
            ok
    end.

%%%===================================================================
%%% Test fixtures
%%%===================================================================

create_mock_release() ->
    TmpDir = make_temp_dir("ocibuild_release"),

    %% Create directory structure using filename:join for cross-platform paths
    BinDir = filename:join(TmpDir, "bin"),
    LibDir = filename:join([TmpDir, "lib", "myapp-1.0.0", "ebin"]),
    RelDir = filename:join([TmpDir, "releases", "1.0.0"]),

    ok =
        filelib:ensure_dir(
            filename:join(BinDir, "placeholder")
        ),
    ok =
        filelib:ensure_dir(
            filename:join(LibDir, "placeholder")
        ),
    ok =
        filelib:ensure_dir(
            filename:join(RelDir, "placeholder")
        ),

    %% Create bin script (executable)
    BinPath = filename:join(BinDir, "myapp"),
    ok = file:write_file(BinPath, <<"#!/bin/sh\nexec erl -boot release">>),
    ok = file:change_mode(BinPath, 8#755),

    %% Create beam file
    BeamPath = filename:join(LibDir, "myapp.beam"),
    ok = file:write_file(BeamPath, <<"FOR1...(beam data)">>),
    ok = file:change_mode(BeamPath, 8#644),

    %% Create release file
    RelPath = filename:join(RelDir, "myapp.rel"),
    ok = file:write_file(RelPath, <<"{release, {\"myapp\", \"1.0.0\"}, ...}.">>),

    TmpDir.
