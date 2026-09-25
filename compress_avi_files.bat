:: ======================================================================
:: COMPRESS_avi_FILES.BAT
:: ----------------------------------------------------------------------
:: Purpose:
::   Batch-compress .avi files in the current directory using ffmpeg,
::   with optional cropping, scaling, gamma, rule-of-thumb denoise/sharpen,
::   and optional concatenation of outputs.
::
:: Behavior notes:
::   - Filter order is crop -> denoise -> scale -> sharpen -> gamma.
::       Denoise operates on near-source pixels (before interpolation);
::       sharpen and grade are applied after scaling.
::   - Audio re-encodes to AAC by default (AUDIO_MODE=aac). Stream-copy of
::       source audio into avi fails for non-avi-legal codecs (PCM/Opus/Vorbis).
::       Set AUDIO_MODE=copy only if all inputs carry AAC/AC3/etc.
::   - Stream-copy concat across AV1_nvenc / mixed-parameter segments is
::       brittle. CONCAT_MODE=auto re-encodes the merged output for AV1 or
::       when COPY is unsafe; CONCAT_MODE=copy forces demuxer stream-copy.
::   - Quality targets are per-encoder (CQ_NVENC, CRF_X264, CRF_SVTAV1);
::       a single value reused across encoders changes the quality point.
::   - CUDA decode is OFF by default when CPU filters are active. Decode-only
::       CUDA forces VRAM->RAM->VRAM round-trips around CPU filters and is
::       frequently slower than CPU decode for filtered pipelines. Opt in with
::       USE_CUDA_WITH_FILTERS=1 only after benchmarking on the target machine.
::   - Concat output is validated with ffprobe (duration vs sum of inputs)
::       rather than relying on ffmpeg's exit code alone.
::   - Anamorphic guard warns if CROP is non-square while SCALE forces both
::       axes (numeric W:H), which would stretch the picture.
::   - Terminal pause is configurable (PAUSE_AT_END) for unattended runs.
::
:: Output:
::   - Individual encoded files in OUT_DIR, one per input file.
::   - Optional concatenated file OUT_DIR\CONCAT_OUTPUT_NAME when ENABLE_CONCAT=1.
::   - Temporary concat list _concat_list.txt in the script directory.
:: ======================================================================

@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =========================
rem  Configuration
rem =========================

rem ffmpeg / ffprobe executables (name on PATH or full path)
set "FFMPEG=ffmpeg"
set "FFPROBE=ffprobe"

rem Input pattern
set "INPUT_MASK=*.avi"

rem Output directory (relative to script directory)
set "OUT_DIR=compressed"

rem Video codec:
rem   CPU / software:  libx264, libsvtav1
rem   NVIDIA NVENC:    h264_nvenc, av1_nvenc
set "VIDEO_CODEC=av1_nvenc"

rem --- Per-encoder quality targets (NOT equivalent across encoders) ---
rem libx264   : 0-51,  lower=better. 18-20 high, 21-23 balanced, 24-28 smaller.
set "CRF_X264=21"
rem libsvtav1 : 0-63,  lower=better. 20-28 high, 29-35 balanced, 36+ smaller.
set "CRF_SVTAV1=30"
rem nvenc     : used as -cq. Lower=better. 19-22 high, 23-28 balanced, 29+ smaller.
set "CQ_NVENC=25"

rem Overwrite behavior: 0 = skip existing outputs, 1 = overwrite
set "OVERWRITE_EXISTING=1"

rem --- Audio ---
rem   aac  : re-encode to AAC (safe for avi; default).
rem   copy : stream-copy source audio (only if avi-legal in ALL inputs).
set "AUDIO_MODE=aac"
set "AAC_BITRATE=192k"

rem --- Crop / scale / gamma ---
rem Examples:
rem   CROP_EXPR=crop=1280:720:0:0       1280x720 from top-left
rem   CROP_EXPR=crop=iw:ih-80:0:40      remove 40px bars top/bottom
rem   SCALE_EXPR=scale=1280:-1          width=1280, preserve aspect (recommended)
rem   SCALE_EXPR=scale=-1:720           height=720, preserve aspect
rem Forcing both axes (scale=W:H) on a non-square crop stretches the image.
set "ENABLE_CROP=1"
set "CROP_EXPR=crop=1122:1122:47:107"

set "ENABLE_SCALE=1"
set "SCALE_EXPR=scale=1200:1200"

set "ENABLE_GAMMA=0"
set "GAMMA_EXPR=eq=gamma=1.5"

rem Rule-of-thumb denoise/sharpen
set "DENOISE=1"
set "SHARPEN=1"

rem --- CUDA decode ---
rem When filters are active, decode-only CUDA round-trips frames through system
rem RAM and is often slower than CPU decode. Keep 0 unless benchmarked faster.
set "USE_CUDA_WITH_FILTERS=0"

rem --- Concatenation ---
set "ENABLE_CONCAT=1"
set "CONCAT_OUTPUT_NAME=all_merged.avi"
rem   auto : copy-concat when safe (matching params, non-AV1); else re-encode.
rem   copy : force demuxer stream-copy (fast; fails on mismatched streams).
rem   reencode : always re-encode the merged output.
set "CONCAT_MODE=auto"
rem Tolerance (seconds) for the ffprobe duration sanity check on the merge.
set "CONCAT_DUR_TOLERANCE=1"

rem --- End behavior ---
rem 1 = pause before exit (interactive). 0 = exit immediately (unattended).
set "PAUSE_AT_END=0"


rem =========================
rem  Pre-flight checks
rem =========================

set "BASE_DIR=%CD%"
set "CONCAT_LIST=%BASE_DIR%\_concat_list.txt"

if "%ENABLE_CONCAT%"=="1" (
    if exist "%CONCAT_LIST%" del /f /q "%CONCAT_LIST%" >nul 2>&1
)

where "%FFMPEG%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: "%FFMPEG%" not found on PATH.
    echo Install ffmpeg or update the FFMPEG variable.
    goto :END
)

set "HAVE_FFPROBE=1"
where "%FFPROBE%" >nul 2>&1
if errorlevel 1 set "HAVE_FFPROBE="

rem -------------------------
rem Resolve active quality target for the chosen codec
rem -------------------------

set "QUALITY="
if /I "%VIDEO_CODEC%"=="libx264"    set "QUALITY=%CRF_X264%"
if /I "%VIDEO_CODEC%"=="libsvtav1"  set "QUALITY=%CRF_SVTAV1%"
if /I "%VIDEO_CODEC%"=="h264_nvenc" set "QUALITY=%CQ_NVENC%"
if /I "%VIDEO_CODEC%"=="av1_nvenc"  set "QUALITY=%CQ_NVENC%"
if not defined QUALITY set "QUALITY=%CRF_X264%"

rem -------------------------
rem Estimate target dimensions (for denoise/sharpen bucket)
rem -------------------------

set "TARGET_W="
set "TARGET_H="
set "TARGET_MAX=0"

if "%ENABLE_SCALE%"=="1" (
    set "SCALE_DIMS="
    for /f "tokens=2 delims==" %%A in ("!SCALE_EXPR!") do set "SCALE_DIMS=%%A"
    for /f "tokens=1,2 delims=:" %%W in ("!SCALE_DIMS!") do (
        set "TARGET_W=%%W"
        set "TARGET_H=%%X"
    )
)

if not defined TARGET_W if "%ENABLE_CROP%"=="1" (
    set "CROP_DIMS="
    for /f "tokens=2 delims==" %%A in ("!CROP_EXPR!") do set "CROP_DIMS=%%A"
    for /f "tokens=1,2 delims=:" %%W in ("!CROP_DIMS!") do (
        set "TARGET_W=%%W"
        set "TARGET_H=%%X"
    )
)

rem Validate numeric (clear non-numeric, e.g. -1 / iw / negative widths)
set "NONNUM="
if defined TARGET_W (
    for /f "delims=0123456789" %%A in ("!TARGET_W!") do set "NONNUM=%%A"
    if defined NONNUM set "TARGET_W="
)
set "NONNUM="
if defined TARGET_H (
    for /f "delims=0123456789" %%A in ("!TARGET_H!") do set "NONNUM=%%A"
    if defined NONNUM set "TARGET_H="
)

if defined TARGET_W (
    set "TARGET_MAX=!TARGET_W!"
    if defined TARGET_H if !TARGET_H! GTR !TARGET_MAX! set "TARGET_MAX=!TARGET_H!"
)

rem -------------------------
rem Anamorphic guard
rem -------------------------

if "%ENABLE_CROP%"=="1" if "%ENABLE_SCALE%"=="1" if defined TARGET_W if defined TARGET_H (
    set "CROP_DIMS="
    for /f "tokens=2 delims==" %%A in ("!CROP_EXPR!") do set "CROP_DIMS=%%A"
    set "CW="
    set "CH="
    for /f "tokens=1,2 delims=:" %%W in ("!CROP_DIMS!") do (
        set "CW=%%W"
        set "CH=%%X"
    )
    set "CW_NONNUM="
    set "CH_NONNUM="
    if defined CW for /f "delims=0123456789" %%A in ("!CW!") do set "CW_NONNUM=%%A"
    if defined CH for /f "delims=0123456789" %%A in ("!CH!") do set "CH_NONNUM=%%A"
    if not defined CW_NONNUM if not defined CH_NONNUM if defined CW if defined CH (
        if not "!CW!"=="!CH!" (
            echo WARNING: CROP is non-square ^(!CW!x!CH!^) but SCALE forces both axes
            echo          ^(!TARGET_W!x!TARGET_H!^). Output will be stretched.
            echo          Use scale=WIDTH:-1 or scale=-1:HEIGHT to preserve aspect.
            echo.
        )
    )
)

rem -------------------------
rem Choose rule-of-thumb filters by max target dimension
rem -------------------------

set "DENOISE_FILTER=hqdn3d=3.0:2.0:4.0:4.0"
set "SHARPEN_FILTER=unsharp=5:5:0.8:5:5:0.0"

if !TARGET_MAX! GTR 0 (
    if !TARGET_MAX! LEQ 1250 (
        set "DENOISE_FILTER=hqdn3d=2.3:1.5:3.0:3.0"
        set "SHARPEN_FILTER=unsharp=3:3:0.7:3:3:0.0"
    ) else (
        if !TARGET_MAX! LEQ 1750 (
            set "DENOISE_FILTER=hqdn3d=3.0:2.0:4.0:4.0"
            set "SHARPEN_FILTER=unsharp=5:5:0.8:5:5:0.0"
        ) else (
            if !TARGET_MAX! LEQ 2250 (
                set "DENOISE_FILTER=hqdn3d=3.7:2.4:4.9:4.9"
                set "SHARPEN_FILTER=unsharp=7:7:0.87:7:7:0.0"
            ) else (
                set "DENOISE_FILTER=hqdn3d=4.4:3.0:5.9:5.9"
                set "SHARPEN_FILTER=unsharp=9:9:0.97:9:9:0.0"
            )
        )
    )
)

rem -------------------------
rem Build video filter chain: crop -> denoise -> scale -> sharpen -> gamma
rem -------------------------

set "VF_ARGS="

if "%ENABLE_CROP%"=="1"   call :append_vf "!CROP_EXPR!"
if "%DENOISE%"=="1"       call :append_vf "!DENOISE_FILTER!"
if "%ENABLE_SCALE%"=="1"  call :append_vf "!SCALE_EXPR!"
if "%SHARPEN%"=="1"       call :append_vf "!SHARPEN_FILTER!"
if "%ENABLE_GAMMA%"=="1"  call :append_vf "!GAMMA_EXPR!"

set "VF_SWITCH="
if defined VF_ARGS set "VF_SWITCH=-vf !VF_ARGS!"

rem -------------------------
rem Detect CUDA hwaccel
rem -------------------------

set "CUDA_AVAILABLE="
for /f "delims=" %%H in ('"%FFMPEG%" -hide_banner -hwaccels 2^>nul ^| findstr /I "cuda"') do set "CUDA_AVAILABLE=1"

rem Decide hwaccel:
rem   No filters + CUDA            -> full GPU path (decode + GPU frames).
rem   Filters + CUDA + opt-in flag -> decode-only CUDA.
rem   Filters + CUDA, no opt-in    -> CPU decode (default; avoids RAM round-trip).
set "HWACCEL_ARGS="
if defined CUDA_AVAILABLE (
    if not defined VF_ARGS (
        set "HWACCEL_ARGS=-hwaccel cuda -hwaccel_output_format cuda"
    ) else (
        if "%USE_CUDA_WITH_FILTERS%"=="1" set "HWACCEL_ARGS=-hwaccel cuda"
    )
)

rem -------------------------
rem Build codec-specific video encoding args
rem -------------------------

set "VENC_ARGS="
if /I "%VIDEO_CODEC%"=="libx264" (
    set "VENC_ARGS=-c:v libx264 -crf %QUALITY% -preset slow"
) else (
    if /I "%VIDEO_CODEC%"=="libsvtav1" (
        set "VENC_ARGS=-c:v libsvtav1 -crf %QUALITY% -preset 6"
    ) else (
        if /I "%VIDEO_CODEC%"=="h264_nvenc" (
            set "VENC_ARGS=-c:v h264_nvenc -preset p6 -tune hq -rc vbr -cq %QUALITY% -b:v 0"
        ) else (
            if /I "%VIDEO_CODEC%"=="av1_nvenc" (
                set "VENC_ARGS=-c:v av1_nvenc -preset p6 -tune hq -rc vbr -cq %QUALITY% -b:v 0"
            ) else (
                set "VENC_ARGS=-c:v %VIDEO_CODEC% -crf %QUALITY%"
            )
        )
    )
)

rem -------------------------
rem Build audio args
rem -------------------------

set "AENC_ARGS="
if /I "%AUDIO_MODE%"=="copy" (
    set "AENC_ARGS=-c:a copy"
) else (
    set "AENC_ARGS=-c:a aac -b:a %AAC_BITRATE%"
)

echo --- avi batch compression ---
echo Current directory: "%BASE_DIR%"
echo Input mask: "%INPUT_MASK%"
echo Output directory: "%OUT_DIR%"
echo Video codec: %VIDEO_CODEC%
echo Quality target: %QUALITY%
echo Audio mode: %AUDIO_MODE%  %AENC_ARGS%
if defined TARGET_W if defined TARGET_H (
    echo Estimated target size: !TARGET_W!x!TARGET_H!
) else (
    echo Estimated target size: unknown ^(default ~1500 denoise/sharpen profile^)
)
echo DENOISE=%DENOISE%  ^|  %DENOISE_FILTER%
echo SHARPEN=%SHARPEN%  ^|  %SHARPEN_FILTER%
echo Video filters: %VF_SWITCH%
if defined CUDA_AVAILABLE (
    echo CUDA hwaccel: available  ^|  USE_CUDA_WITH_FILTERS=%USE_CUDA_WITH_FILTERS%
    echo HWACCEL args: %HWACCEL_ARGS%
) else (
    echo CUDA hwaccel: not detected
)
echo Video encode args: %VENC_ARGS%
if not defined HAVE_FFPROBE echo NOTE: ffprobe not found; concat duration check disabled.
echo.

if /I not "%VIDEO_CODEC%"=="libx264" if /I not "%VIDEO_CODEC%"=="libsvtav1" if /I not "%VIDEO_CODEC%"=="h264_nvenc" if /I not "%VIDEO_CODEC%"=="av1_nvenc" (
    echo WARNING: VIDEO_CODEC "%VIDEO_CODEC%" is not a known preset. Passing as-is with -crf.
)

if not exist %INPUT_MASK% (
    echo No files matching "%INPUT_MASK%" found in "%BASE_DIR%".
    goto :END
)

if not exist "%OUT_DIR%\" (
    mkdir "%OUT_DIR%" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Failed to create output directory "%OUT_DIR%".
        goto :END
    )
)

set "TOTAL=0"
for %%F in (%INPUT_MASK%) do set /a TOTAL+=1
echo Found %TOTAL% file^(s^) to process.
echo.


rem =========================
rem  Main loop
rem =========================

set "DONE=0"
set "FAILED=0"
set "SKIPPED=0"
set "SUM_DUR=0"

for %%F in (%INPUT_MASK%) do (
    set "BASENAME=%%~nF"
    set "OUT_PATH=%OUT_DIR%\!BASENAME!.avi"
    set "DO_SKIP=0"

    if exist "!OUT_PATH!" (
        if "%OVERWRITE_EXISTING%"=="0" (
            echo Skipping "%%F"  ^>  "!OUT_PATH!"  ^(exists, OVERWRITE_EXISTING=0^)
            set "DO_SKIP=1"
            set /a SKIPPED+=1
        ) else (
            echo Overwriting "%%F"  ^>  "!OUT_PATH!"
        )
    ) else (
        echo Compressing "%%F"  ^>  "!OUT_PATH!"
    )

    if "!DO_SKIP!"=="0" (
        "%FFMPEG%" -y -hide_banner -loglevel error -err_detect ignore_err ^
            %HWACCEL_ARGS% ^
            -i "%%F" ^
            !VENC_ARGS! %VF_SWITCH% %AENC_ARGS% ^
            "!OUT_PATH!"

        if errorlevel 1 (
            echo   ERROR: ffmpeg failed for "%%F".
            set /a FAILED+=1
        ) else (
            echo   OK
            set /a DONE+=1

            if "%ENABLE_CONCAT%"=="1" (
                set "OUT_PATH_FULL=%BASE_DIR%\!OUT_PATH!"
                >>"%CONCAT_LIST%" echo file '!OUT_PATH_FULL!'

                if defined HAVE_FFPROBE (
                    set "DUR="
                    for /f "usebackq delims=" %%D in (`"%FFPROBE%" -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 "!OUT_PATH!"`) do set "DUR=%%D"
                    if defined DUR call :add_duration "!DUR!"
                )
            )
        )
    )
    echo.
)

rem =========================
rem  Concatenation
rem =========================

if "%ENABLE_CONCAT%"=="1" (
    if !DONE! GTR 0 (
        if exist "%CONCAT_LIST%" (
            set "CONCAT_OUT=%OUT_DIR%\%CONCAT_OUTPUT_NAME%"

            rem Decide copy vs re-encode.
            set "DO_REENCODE=0"
            if /I "%CONCAT_MODE%"=="reencode" set "DO_REENCODE=1"
            if /I "%CONCAT_MODE%"=="auto" (
                rem AV1-in-avi copy-concat is brittle; re-encode under auto.
                if /I "%VIDEO_CODEC%"=="av1_nvenc"  set "DO_REENCODE=1"
                if /I "%VIDEO_CODEC%"=="libsvtav1"  set "DO_REENCODE=1"
                rem Non-AAC copied audio cannot be safely copy-concatenated.
                if /I "%AUDIO_MODE%"=="copy"        set "DO_REENCODE=1"
            )

            if "!DO_REENCODE!"=="1" (
                echo Concatenating !DONE! file^(s^) ^(re-encode^) into "!CONCAT_OUT!"...
                "%FFMPEG%" -y -hide_banner -loglevel error -err_detect ignore_err ^
                    -f concat -safe 0 -i "%CONCAT_LIST%" ^
                    !VENC_ARGS! %AENC_ARGS% ^
                    "!CONCAT_OUT!"
            ) else (
                echo Concatenating !DONE! file^(s^) ^(stream copy^) into "!CONCAT_OUT!"...
                "%FFMPEG%" -y -hide_banner -loglevel error -err_detect ignore_err ^
                    -f concat -safe 0 -i "%CONCAT_LIST%" -c copy ^
                    "!CONCAT_OUT!"
            )

            if errorlevel 1 (
                echo   ERROR: ffmpeg failed during concatenation.
            ) else (
                rem Validate: merged duration vs sum of segment durations.
                if defined HAVE_FFPROBE (
                    set "MERGE_DUR="
                    for /f "usebackq delims=" %%D in (`"%FFPROBE%" -v error -show_entries format^=duration -of default^=noprint_wrappers^=1:nokey^=1 "!CONCAT_OUT!"`) do set "MERGE_DUR=%%D"
                    call :check_merge_duration "!MERGE_DUR!"
                ) else (
                    echo   Concatenation finished ^(duration check skipped: no ffprobe^).
                )
            )
        ) else (
            echo CONCAT: No concatenation list found; skipping.
        )
    ) else (
        echo CONCAT: No successfully processed files; skipping concatenation.
    )
)

echo.
echo =========================
echo Summary
echo =========================
echo   Total candidates : %TOTAL%
echo   Successfully done: %DONE%
echo   Skipped          : %SKIPPED%
echo   Failed           : %FAILED%
if "%ENABLE_CONCAT%"=="1" echo   Concatenated     : "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"
echo   Output folder    : "%OUT_DIR%"
echo.

goto :END


rem =========================
rem  Subroutines
rem =========================

:append_vf
rem %~1 = filter expression to append to VF_ARGS
if defined VF_ARGS (
    set "VF_ARGS=!VF_ARGS!,%~1"
) else (
    set "VF_ARGS=%~1"
)
goto :eof

:add_duration
rem %~1 = duration in seconds (float). Accumulate into SUM_DUR using integer seconds.
rem cmd has no float math; truncate to whole seconds for the sanity check.
set "_D=%~1"
for /f "tokens=1 delims=." %%I in ("!_D!") do set "_DI=%%I"
if not defined _DI set "_DI=0"
set "_NONNUM="
for /f "delims=0123456789" %%A in ("!_DI!") do set "_NONNUM=%%A"
if defined _NONNUM set "_DI=0"
set /a SUM_DUR+=_DI
goto :eof

:check_merge_duration
rem %~1 = merged duration (float). Compare truncated seconds vs SUM_DUR +/- tolerance.
set "_M=%~1"
if not defined _M (
    echo   Concatenation finished ^(duration unknown; could not probe merge^).
    goto :eof
)
for /f "tokens=1 delims=." %%I in ("!_M!") do set "_MI=%%I"
if not defined _MI set "_MI=0"
set "_NONNUM="
for /f "delims=0123456789" %%A in ("!_MI!") do set "_NONNUM=%%A"
if defined _NONNUM set "_MI=0"

set /a _DIFF=_MI-SUM_DUR
if !_DIFF! LSS 0 set /a _DIFF=-_DIFF
if !_DIFF! LEQ %CONCAT_DUR_TOLERANCE% (
    echo   Concatenation OK ^(merged ~!_MI!s vs sum ~%SUM_DUR%s^).
) else (
    echo   WARNING: merged duration ~!_MI!s differs from sum ~%SUM_DUR%s by !_DIFF!s.
    echo            Segments may have mismatched timebase/params or copy-concat lost data.
    echo            Try CONCAT_MODE=reencode.
)
goto :eof


:END
if "%PAUSE_AT_END%"=="1" pause
endlocal
