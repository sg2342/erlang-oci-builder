%%%-------------------------------------------------------------------
-module(ocibuild_compress).
-moduledoc """
Compression abstraction with automatic OTP version detection.

This module provides a unified compression API that automatically selects
the best available compression algorithm based on the OTP version:

- **OTP 28+**: zstd available (20-50% smaller, 5-10x faster decompression)
- **OTP 27**: gzip only

## Usage

```erlang
%% Auto-select best available compression
{ok, Compressed} = ocibuild_compress:compress(Data, auto).

%% Explicit compression selection
{ok, Compressed} = ocibuild_compress:compress(Data, gzip).
{ok, Compressed} = ocibuild_compress:compress(Data, zstd).  % Fails on OTP 27

%% Check availability
true = ocibuild_compress:is_available(gzip).
false = ocibuild_compress:is_available(zstd).  % On OTP 27

%% Get default compression for current OTP
gzip = ocibuild_compress:default().  % On OTP 27
zstd = ocibuild_compress:default().  % On OTP 28+
```
""".

-export([compress/2, is_available/1, default/0, resolve/1]).

%%%===================================================================
%%% Types
%%%===================================================================

-type compression() :: gzip | zstd | auto.
-type resolved_compression() :: gzip | zstd.

-export_type([compression/0, resolved_compression/0]).

%%%===================================================================
%%% API
%%%===================================================================

-doc """
Returns the best available compression for the current OTP version.

Returns `zstd` on OTP 28+ (better compression ratio and faster decompression),
or `gzip` on OTP 27 and earlier.
""".
-spec default() -> resolved_compression().
default() ->
    case is_available(zstd) of
        true -> zstd;
        false -> gzip
    end.

-doc """
Resolve `auto` to the actual compression algorithm.

```erlang
gzip = ocibuild_compress:resolve(auto).  % On OTP 27
zstd = ocibuild_compress:resolve(auto).  % On OTP 28+
gzip = ocibuild_compress:resolve(gzip).
zstd = ocibuild_compress:resolve(zstd).
```
""".
-spec resolve(compression()) -> resolved_compression().
resolve(auto) -> default();
resolve(gzip) -> gzip;
resolve(zstd) -> zstd.

-doc """
Check if a compression algorithm is available on the current OTP version.

```erlang
true = ocibuild_compress:is_available(gzip).   % Always available
true = ocibuild_compress:is_available(auto).   % Always available
true = ocibuild_compress:is_available(zstd).   % Only on OTP 28+
```
""".
-spec is_available(compression()) -> boolean().
is_available(gzip) -> true;
is_available(auto) -> true;
is_available(zstd) ->
    %% Runtime check for OTP 28+ zstd module in stdlib
    %% We check if the module is loadable, not just if it exists
    case code:ensure_loaded(zstd) of
        {module, zstd} -> true;
        {error, _} -> false
    end.

-doc """
Compress data using the specified algorithm.

Returns `{ok, CompressedData}` on success, or `{error, Reason}` on failure.

```erlang
%% Auto-select best available
{ok, Compressed} = ocibuild_compress:compress(Data, auto).

%% Explicit gzip (always available)
{ok, Compressed} = ocibuild_compress:compress(Data, gzip).

%% Explicit zstd (OTP 28+ only)
{ok, Compressed} = ocibuild_compress:compress(Data, zstd).
{error, {zstd_not_available, otp_version, "27"}} = ...  % On OTP 27
```
""".
-spec compress(Data, Compression) -> Result when
    Data :: iodata(),
    Compression :: compression(),
    Result :: {ok, binary()} | {error, term()}.
compress(Data, auto) ->
    compress(Data, default());
compress(Data, gzip) ->
    try
        {ok, zlib:gzip(Data)}
    catch
        error:Reason ->
            {error, {gzip_failed, Reason}}
    end;
compress(Data, zstd) ->
    case is_available(zstd) of
        true ->
            try
                %% zstd:compress/1 is available in OTP 28+
                %% It returns an iolist, so convert to binary
                {ok, iolist_to_binary(zstd:compress(Data))}
            catch
                error:Reason ->
                    {error, {zstd_failed, Reason}}
            end;
        false ->
            OtpVersion = erlang:system_info(otp_release),
            {error, {zstd_not_available, otp_version, OtpVersion}}
    end.
