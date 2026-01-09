%%%-------------------------------------------------------------------
-module(ocibuild_tar_tests).
-moduledoc "Tests for `ocibuild_tar` module".

-include_lib("eunit/include/eunit.hrl").

-import(ocibuild_test_helpers, [make_temp_dir/1, cleanup_temp_dir/1]).

%%%===================================================================
%%% Basic tests
%%%===================================================================

tar_basic_test() ->
    Files = [{~"/hello.txt", ~"Hello, World!", 8#644}],
    Tar = ocibuild_tar:create(Files),
    %% TAR should be a multiple of 512 bytes
    ?assertEqual(0, byte_size(Tar) rem 512),
    %% Should contain at least the file content
    ?assert(binary:match(Tar, ~"Hello, World!") =/= nomatch).

tar_empty_files_test() ->
    %% Test with no files - should still produce valid TAR with end marker
    Tar = ocibuild_tar:create([]),
    %% Should be two 512-byte zero blocks (end marker)
    ?assertEqual(1024, byte_size(Tar)).

tar_multiple_directories_test() ->
    %% Test with deeply nested directories
    Files = [
        {~"/a/b/c/file1.txt", ~"content1", 8#644},
        {~"/a/b/file2.txt", ~"content2", 8#644},
        {~"/x/y/z/file3.txt", ~"content3", 8#755}
    ],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512),
    %% Should contain all content
    ?assert(binary:match(Tar, ~"content1") =/= nomatch),
    ?assert(binary:match(Tar, ~"content2") =/= nomatch),
    ?assert(binary:match(Tar, ~"content3") =/= nomatch).

tar_large_content_test() ->
    %% Test with content that spans multiple blocks
    LargeContent = binary:copy(~"0123456789", 100),
    Files = [{~"/large.txt", LargeContent, 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512),
    ?assert(byte_size(Tar) > 1024).

tar_exact_block_size_test() ->
    %% Test content exactly 512 bytes (should need no padding)
    Content = binary:copy(~"X", 512),
    Files = [{~"/exact.txt", Content, 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512).

tar_root_file_test() ->
    %% Test file at root level without leading slash
    Files = [{~"rootfile.txt", ~"content", 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512),
    ?assert(binary:match(Tar, ~"content") =/= nomatch).

%%%===================================================================
%%% Path normalization tests
%%%===================================================================

tar_already_normalized_path_test() ->
    %% Test paths that start with ./
    Files = [{~"./already/normalized/file.txt", ~"content", 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512).

tar_safe_dots_test() ->
    %% Test that single dot and filenames with dots are allowed
    Files = [
        {~"/some.file.with.dots.txt", ~"content1", 8#644},
        {~"/dir.with.dots/file.txt", ~"content2", 8#644}
    ],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512).

%%%===================================================================
%%% Security tests
%%%===================================================================

%% Security test: path traversal sequences must be rejected
tar_path_traversal_test() ->
    %% Paths with ".." components should raise error
    TraversalPaths = [
        ~"../etc/passwd",
        ~"foo/../../../etc/passwd",
        ~"/app/../etc/shadow",
        ~".."
    ],
    lists:foreach(
        fun(Path) ->
            Files = [{Path, ~"malicious content", 8#644}],
            ?assertError(
                {path_traversal, _},
                ocibuild_tar:create(Files)
            )
        end,
        TraversalPaths
    ).

tar_null_byte_injection_test() ->
    %% Paths with null bytes should raise error (security vulnerability)
    NullPaths = [
        <<"/app/file.txt", 0, ".evil">>,
        <<"/app/", 0, "passwd">>,
        <<0, "/etc/shadow">>
    ],
    lists:foreach(
        fun(Path) ->
            Files = [{Path, ~"content", 8#644}],
            ?assertError(
                {null_byte, _},
                ocibuild_tar:create(Files)
            )
        end,
        NullPaths
    ).

tar_empty_path_test() ->
    %% Empty paths should raise error
    Files = [{<<>>, ~"content", 8#644}],
    ?assertError(
        {empty_path, _},
        ocibuild_tar:create(Files)
    ).

%%%===================================================================
%%% File mode tests
%%%===================================================================

tar_invalid_mode_test() ->
    %% Invalid modes should raise error
    InvalidModes = [
        %% Negative
        -1,
        %% Exceeds 7777 octal
        8#10000,
        %% Way too large
        16#FFFF
    ],
    lists:foreach(
        fun(Mode) ->
            Files = [{~"/app/file.txt", ~"content", Mode}],
            ?assertError(
                {invalid_mode, Mode},
                ocibuild_tar:create(Files)
            )
        end,
        InvalidModes
    ).

tar_valid_mode_edge_cases_test() ->
    %% Valid mode edge cases should work
    ValidModes = [
        %% Minimum
        0,
        %% Common file mode
        8#644,
        %% Common executable mode
        8#755,
        %% Maximum (with setuid, setgid, sticky)
        8#7777
    ],
    lists:foreach(
        fun(Mode) ->
            Files = [{~"/app/file.txt", ~"content", Mode}],
            Tar = ocibuild_tar:create(Files),
            ?assertEqual(0, byte_size(Tar) rem 512)
        end,
        ValidModes
    ).

tar_various_permissions_test() ->
    %% Test different file permissions
    Files = [
        {~"/script.sh", ~"#!/bin/sh", 8#755},
        {~"/readonly.txt", ~"readonly", 8#444},
        {~"/private.key", ~"secret", 8#600}
    ],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512).

%%%===================================================================
%%% Duplicate path tests
%%%===================================================================

tar_duplicate_paths_test() ->
    %% Duplicate paths should raise error (reports normalized path)
    Files = [
        {~"/app/file.txt", ~"content1", 8#644},
        {~"/app/other.txt", ~"content2", 8#644},
        %% Duplicate!
        {~"/app/file.txt", ~"content3", 8#644}
    ],
    ?assertError(
        {duplicate_paths, [~"./app/file.txt"]},
        ocibuild_tar:create(Files)
    ).

tar_duplicate_paths_after_normalization_test() ->
    %% Paths that normalize to the same value should be detected as duplicates
    %% "/app/file.txt" and "app/file.txt" both normalize to "./app/file.txt"
    Files = [
        {~"/app/file.txt", ~"content1", 8#644},
        {~"app/file.txt", ~"content2", 8#644}
    ],
    ?assertError(
        {duplicate_paths, [~"./app/file.txt"]},
        ocibuild_tar:create(Files)
    ).

%%%===================================================================
%%% Long path tests (ustar prefix field)
%%%===================================================================

tar_long_path_test() ->
    %% Test path that exceeds 100 characters (requires prefix field)
    LongDir = binary:copy(~"subdir/", 20),
    LongPath = <<LongDir/binary, "file.txt">>,
    Files = [{LongPath, ~"test", 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512).

%%%===================================================================
%%% PAX extended header tests
%%%===================================================================

tar_pax_long_filename_test() ->
    %% Test filename > 100 bytes that cannot be split (requires PAX header)
    %% This simulates the AshAuthentication issue from GitHub #21
    LongFilename =
        <<"Elixir.AshAuthentication.Strategy.Password.Authentication.",
            "Strategies.Password.Resettable.Options.beam">>,
    ?assert(byte_size(LongFilename) > 100),
    Path = <<"/app/lib/myapp/ebin/", LongFilename/binary>>,
    Content = <<"BEAM content here">>,
    Files = [{Path, Content, 8#644}],
    Tar = ocibuild_tar:create(Files),
    %% Archive should be valid (multiple of 512)
    ?assertEqual(0, byte_size(Tar) rem 512),
    %% Should contain PAX header (typeflag 'x')
    ?assertNotEqual(nomatch, binary:match(Tar, <<"path=">>)),
    %% Should contain the full filename in PAX data
    ?assertNotEqual(nomatch, binary:match(Tar, LongFilename)).

%% PAX extraction test fixture
setup_pax_tempdir() ->
    make_temp_dir("pax_test").

cleanup_pax_tempdir(TmpDir) ->
    cleanup_temp_dir(TmpDir).

tar_pax_extraction_test_() ->
    {foreach, fun setup_pax_tempdir/0, fun cleanup_pax_tempdir/1, [
        fun(TmpDir) ->
            {"PAX extracts correctly", fun() -> tar_pax_extracts_correctly_test(TmpDir) end}
        end
    ]}.

tar_pax_extracts_correctly_test(TmpDir) ->
    %% Verify PAX archive can be extracted by system tar
    LongFilename =
        <<"Elixir.VeryLongModuleName.WithMany.Nested.Modules.",
            "That.Exceed.The.Hundred.Byte.Limit.In.Ustar.beam">>,
    Path = <<"/app/lib/myapp/ebin/", LongFilename/binary>>,
    Content = <<"test content 12345">>,
    Files = [{Path, Content, 8#644}],
    Tar = ocibuild_tar:create(Files),

    %% Write tar and extract with system tar
    TarFile = filename:join(TmpDir, "test.tar"),
    ok = file:write_file(TarFile, Tar),
    Cmd = "tar -xf " ++ TarFile ++ " -C " ++ TmpDir,
    _ = os:cmd(Cmd),

    %% Verify extracted file exists and has correct content
    ExtractedPath = filename:join([
        TmpDir,
        ".",
        "app",
        "lib",
        "myapp",
        "ebin",
        binary_to_list(LongFilename)
    ]),
    ?assert(filelib:is_regular(ExtractedPath)),
    ?assertEqual({ok, Content}, file:read_file(ExtractedPath)).

tar_pax_very_long_path_test() ->
    %% Test extremely long path (> 255 bytes, exceeds ustar entirely)
    DeepPath = binary:copy(<<"very_long_directory_name/">>, 15),
    Filename = <<"file.txt">>,
    Path = <<"/", DeepPath/binary, Filename/binary>>,
    ?assert(byte_size(Path) > 255),
    Content = <<"deep content">>,
    Files = [{Path, Content, 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512),
    ?assertNotEqual(nomatch, binary:match(Tar, <<"path=">>)).

tar_ustar_still_used_when_possible_test() ->
    %% Verify short paths don't use PAX (efficiency)
    Files = [{~"/short/path.txt", ~"content", 8#644}],
    Tar = ocibuild_tar:create(Files),
    ?assertEqual(0, byte_size(Tar) rem 512),
    %% Should NOT contain PAX header for short paths
    ?assertEqual(nomatch, binary:match(Tar, <<"path=">>)).

%%%===================================================================
%%% Reproducibility tests
%%%===================================================================

tar_file_sorting_test() ->
    %% Test that files are sorted regardless of input order
    Files = [
        {~"/z/file.txt", ~"z", 8#644},
        {~"/a/file.txt", ~"a", 8#644},
        {~"/m/file.txt", ~"m", 8#644}
    ],
    MTime = 1700000000,
    Tar1 = ocibuild_tar:create(Files, #{mtime => MTime}),
    %% Same files in different order
    Tar2 = ocibuild_tar:create(lists:reverse(Files), #{mtime => MTime}),
    %% Should produce identical output
    ?assertEqual(Tar1, Tar2).

tar_mtime_option_test() ->
    %% Test that mtime option is used
    Files = [{~"/test.txt", ~"content", 8#644}],
    FixedTime = 1234567890,
    Tar1 = ocibuild_tar:create(Files, #{mtime => FixedTime}),
    Tar2 = ocibuild_tar:create(Files, #{mtime => FixedTime}),
    ?assertEqual(Tar1, Tar2),
    %% Verify digests match
    ?assertEqual(ocibuild_digest:sha256(Tar1), ocibuild_digest:sha256(Tar2)).

tar_reproducible_test() ->
    %% Test full reproducibility with fixed mtime
    Files = [
        {~"/app/bin/myapp", ~"#!/bin/sh\necho hello", 8#755},
        {~"/app/config.json", ~"{\"key\": \"value\"}", 8#644}
    ],
    MTime = 1700000000,
    %% Create twice with same mtime
    Tar1 = ocibuild_tar:create(Files, #{mtime => MTime}),
    Tar2 = ocibuild_tar:create(Files, #{mtime => MTime}),
    ?assertEqual(Tar1, Tar2),
    %% Verify the digests match
    ?assertEqual(ocibuild_digest:sha256(Tar1), ocibuild_digest:sha256(Tar2)).
