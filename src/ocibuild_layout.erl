%%%-------------------------------------------------------------------
-module(ocibuild_layout).
-moduledoc """
OCI image layout handling.

Produces OCI Image Layout format for use with `podman load`,
`skopeo`, or direct filesystem storage.

The layout structure is:
```
myimage/
├── oci-layout           # {"imageLayoutVersion": "1.0.0"}
├── index.json           # Entry point
└── blobs/
    └── sha256/
        ├── <manifest>   # Manifest JSON
        ├── <config>     # Config JSON
        └── <layers...>  # Layer tarballs (gzip compressed)
```

See: https://github.com/opencontainers/image-spec/blob/main/image-layout.md
""".

-export([export_directory/2, save_tarball/2, save_tarball/3]).

-doc """
Export image as an OCI layout directory.

Creates the standard OCI directory structure at the given path.
```
ok = ocibuild_layout:export_directory(Image, "./myimage").
```
""".
-spec export_directory(ocibuild:image(), file:filename()) -> ok | {error, term()}.
export_directory(Image, Path) ->
    try
        %% Create directory structure
        BlobsDir = filename:join([Path, "blobs", "sha256"]),
        ok =
            filelib:ensure_dir(
                filename:join(BlobsDir, "dummy")),

        %% Build all the components
        {ConfigJson, ConfigDigest} = build_config_blob(Image),
        LayerDescriptors = build_layer_descriptors(Image),
        {ManifestJson, ManifestDigest} =
            ocibuild_manifest:build(#{~"mediaType" =>
                                          ~"application/vnd.oci.image.config.v1+json",
                                      ~"digest" => ConfigDigest,
                                      ~"size" => byte_size(ConfigJson)},
                                    LayerDescriptors),

        %% Write oci-layout
        OciLayout = ocibuild_json:encode(#{~"imageLayoutVersion" => ~"1.0.0"}),
        ok =
            file:write_file(
                filename:join(Path, "oci-layout"), OciLayout),

        %% Write index.json
        Index = build_index(ManifestDigest, byte_size(ManifestJson), ~"latest"),
        IndexJson = ocibuild_json:encode(Index),
        ok =
            file:write_file(
                filename:join(Path, "index.json"), IndexJson),

        %% Write config blob
        ConfigPath = filename:join(BlobsDir, ocibuild_digest:encoded(ConfigDigest)),
        ok = file:write_file(ConfigPath, ConfigJson),

        %% Write manifest blob
        ManifestPath = filename:join(BlobsDir, ocibuild_digest:encoded(ManifestDigest)),
        ok = file:write_file(ManifestPath, ManifestJson),

        %% Write layer blobs
        lists:foreach(fun(#{digest := Digest, data := Data}) ->
                         LayerPath = filename:join(BlobsDir, ocibuild_digest:encoded(Digest)),
                         ok = file:write_file(LayerPath, Data)
                      end,
                      maps:get(layers, Image, [])),

        ok
    catch
        error:Reason ->
            {error, Reason}
    end.

-doc """
Save image as an OCI layout tarball.

Creates a tar.gz file that can be loaded with `podman load` or other OCI-compliant tools.
```
ok = ocibuild_layout:save_tarball(Image, "./myimage.tar.gz").
ok = ocibuild_layout:save_tarball(Image, "./myimage.tar.gz", #{tag => <<"myapp:1.0">>}).
```

Options:
- `tag`: Image tag annotation (e.g., `<<"myapp:1.0">>`)

Note: OCI layout works with podman, skopeo, crane, buildah, and other OCI tools.
""".
-spec save_tarball(ocibuild:image(), file:filename()) -> ok | {error, term()}.
save_tarball(Image, Path) ->
    save_tarball(Image, Path, #{}).

-spec save_tarball(ocibuild:image(), file:filename(), map()) -> ok | {error, term()}.
save_tarball(Image, Path, Opts) ->
    try
        Tag = maps:get(tag, Opts, ~"latest"),

        %% Build all the blobs and metadata
        {ConfigJson, ConfigDigest} = build_config_blob(Image),
        LayerDescriptors = build_layer_descriptors(Image),
        {ManifestJson, ManifestDigest} =
            ocibuild_manifest:build(#{~"mediaType" =>
                                          ~"application/vnd.oci.image.config.v1+json",
                                      ~"digest" => ConfigDigest,
                                      ~"size" => byte_size(ConfigJson)},
                                    LayerDescriptors),

        %% Build oci-layout
        OciLayout = ocibuild_json:encode(#{~"imageLayoutVersion" => ~"1.0.0"}),

        %% Build index.json with tag annotation for podman/skopeo
        Index = build_index(ManifestDigest, byte_size(ManifestJson), Tag),
        IndexJson = ocibuild_json:encode(Index),

        %% Collect all files for the tarball
        %% Include base image layers if available
        BaseLayerFiles = build_base_layers(Image),

        Files =
            [{~"oci-layout", OciLayout, 8#644},
             {~"index.json", IndexJson, 8#644},
             {blob_path(ConfigDigest), ConfigJson, 8#644},
             {blob_path(ManifestDigest), ManifestJson, 8#644}]
            ++ [{blob_path(Digest), Data, 8#644}
                || #{digest := Digest, data := Data} <- maps:get(layers, Image, [])]
            ++ BaseLayerFiles,

        %% Create the tarball
        TarData = ocibuild_tar:create(Files),
        Compressed = zlib:gzip(TarData),

        ok = file:write_file(Path, Compressed)
    catch
        error:Reason ->
            {error, Reason}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Download base image layers from registry
-spec build_base_layers(ocibuild:image()) -> [{binary(), binary(), integer()}].
build_base_layers(#{base := {Registry, Repo, _Tag},
                    base_manifest := #{~"layers" := ManifestLayers}}) ->
    lists:foldl(
        fun(#{~"digest" := Digest}, Acc) ->
            case ocibuild_registry:pull_blob(Registry, Repo, Digest) of
                {ok, CompressedData} ->
                    %% OCI format keeps layers compressed with digest as path
                    Acc ++ [{blob_path(Digest), CompressedData, 8#644}];
                {error, Reason} ->
                    io:format(standard_error, "Warning: Could not fetch base layer ~s: ~p~n",
                              [Digest, Reason]),
                    Acc
            end
        end,
        [],
        ManifestLayers
    );
build_base_layers(_Image) ->
    [].

%% Build the config JSON blob
-spec build_config_blob(ocibuild:image()) -> {binary(), binary()}.
build_config_blob(#{config := Config}) ->
    Json = ocibuild_json:encode(Config),
    Digest = ocibuild_digest:sha256(Json),
    {Json, Digest}.

%% Build layer descriptors for the manifest
-spec build_layer_descriptors(ocibuild:image()) -> [map()].
build_layer_descriptors(#{base_manifest := BaseManifest, layers := NewLayers}) ->
    %% Include base image layers + new layers
    BaseLayers = maps:get(~"layers", BaseManifest, []),
    NewDescriptors =
        [#{~"mediaType" => MediaType,
           ~"digest" => Digest,
           ~"size" => Size}
         || #{media_type := MediaType,
              digest := Digest,
              size := Size}
                <- NewLayers],
    BaseLayers ++ NewDescriptors;
build_layer_descriptors(#{layers := NewLayers}) ->
    %% No base image, just new layers
    [#{~"mediaType" => MediaType,
       ~"digest" => Digest,
       ~"size" => Size}
     || #{media_type := MediaType,
          digest := Digest,
          size := Size}
            <- NewLayers].

%% Build the index.json structure with tag annotation
-spec build_index(binary(), non_neg_integer(), binary()) -> map().
build_index(ManifestDigest, ManifestSize, Tag) ->
    #{~"schemaVersion" => 2,
      ~"manifests" =>
          [#{~"mediaType" => ~"application/vnd.oci.image.manifest.v1+json",
             ~"digest" => ManifestDigest,
             ~"size" => ManifestSize,
             ~"annotations" => #{
                 %% This annotation tells podman/skopeo what to name the image
                 ~"org.opencontainers.image.ref.name" => Tag
             }}]}.

%% Convert digest to blob path
-spec blob_path(binary()) -> binary().
blob_path(Digest) ->
    Encoded = ocibuild_digest:encoded(Digest),
    <<"blobs/sha256/", Encoded/binary>>.
