:: ======================================================================
:: COMPRESS_MP4_FILES.BAT
:: ----------------------------------------------------------------------
:: Purpose:
::   Batch-compress .mp4 files in the current directory using ffmpeg,
::   with optional cropping, scaling, rotation, rule-of-thumb denoise/sharpen,
::   optional faststart, optional audio fallback, and optional concatenation.
::
:: Behavior:
::   - Scans the current directory for files matching INPUT_MASK (default: *.mp4).
::   - Encodes each file into OUT_DIR using a selectable video codec.
::   - Applies codec-appropriate quality flags automatically:
::       * libx264 / libsvtav1     -> -crf
::       * h264_nvenc / av1_nvenc -> -rc vbr -cq (CRF variable reused as CQ target)
::   - Builds a -vf filter chain from enabled stages:
::       crop -> scale -> rotate -> denoise -> sharpen
::   - Denoise/sharpen use rule-of-thumb parameters based on the
::     estimated output dimensions.
::   - Optionally concatenates all successfully processed outputs into one file
::     using ffmpeg’s concat demuxer (stream copy, no re-encode).
::   - Attempts to enable CUDA hardware decode when available.
::       * IMPORTANT: Forcing GPU output frames (-hwaccel_output_format cuda)
::         conflicts with CPU-only filters (crop/scale/transpose/hqdn3d/unsharp).
::         This script enables that flag only when no -vf filters are set.
::
:: Robustness additions vs original:
::   - Safer per-file processing using a subroutine to reduce delayed-expansion
::     filename hazards (notably filenames containing '!').
::   - More reliable "no input files" detection.
::   - Optional audio fallback to AAC if -c:a copy fails.
::   - Concat list stored inside OUT_DIR with paths relative to list file.
::   - Optional -movflags +faststart.
::
:: Configuration:
::   - FFMPEG              : ffmpeg executable name or full path.
::   - INPUT_MASK          : glob for input files (e.g. *.mp4).
::   - OUT_DIR             : output directory.
::   - VIDEO_CODEC         : libx264, libsvtav1, h264_nvenc, av1_nvenc, or other ffmpeg encoder name.
::   - CRF                 : quality target (range notes below).
::   - OVERWRITE_EXISTING  : 0 = skip existing outputs, 1 = overwrite outputs.
::   - ENABLE_CROP         : 0 = no crop, 1 = apply CROP_EXPR.
::   - CROP_EXPR           : ffmpeg crop expression (e.g. crop=1280:720:0:0).
::   - ENABLE_SCALE        : 0 = no scale, 1 = apply SCALE_EXPR.
::   - SCALE_EXPR          : ffmpeg scale expression (e.g. scale=1280:-1).
::   - ROTATE_MODE         : 0 = none, 1 = 90° CW, 2 = 90° CCW, 3 = 180°.
::   - DENOISE             : 0 = no denoise, 1 = add hqdn3d rule-of-thumb.
::   - SHARPEN             : 0 = no sharpen, 1 = add unsharp rule-of-thumb.
::   - ENABLE_CONCAT       : 0 = no concat, 1 = concat all successful outputs.
::   - CONCAT_OUTPUT_NAME  : final concatenated file name inside OUT_DIR.
::   - FASTSTART           : 0/1 add -movflags +faststart.
::   - AUDIO_FALLBACK_AAC  : 0/1 retry with AAC if audio copy fails.
::   - AUDIO_BITRATE       : AAC bitrate for fallback.
::
:: Rotation note:
::   - Rotation is applied after crop/scale.
::   - This means your absolute crop coordinates (crop=W:H:X:Y) can stay
::     defined in the original orientation.
::   - If you need a square crop from a rotated view, adjust CROP_EXPR/scale
::     accordingly.
::
:: Rule-of-thumb mapping (based on estimated output size):
::   If output ~1000×1000:
::     hqdn3d=2.3:1.5:3.0:3.0
::     unsharp=3:3:0.7:3:3:0.0
::   If output ~1500×1500:
::     hqdn3d=3.0:2.0:4.0:4.0
::     unsharp=5:5:0.8:5:5:0.0
::   If output ~2000×2000:
::     hqdn3d=3.7:2.4:4.9:4.9
::     unsharp=7:7:0.87:7:7:0.0
::   If output ~2500–3000:
::     hqdn3d=4.4:3.0:5.9:5.9
::     unsharp=9:9:0.97:9:9:0.0
::
:: Estimation logic for denoise/sharpen:
::   - If ENABLE_SCALE=1 and SCALE_EXPR is numeric (scale=W:H), use W/H.
::   - Else if ENABLE_CROP=1, use crop W/H from CROP_EXPR.
::   - Else fall back to the ~1500 profile.
::   - For ROTATE_MODE 1 or 2, displayed estimated size is swapped.
::
:: Requirements:
::   - ffmpeg built with the chosen VIDEO_CODEC.
:: ======================================================================

@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =========================
rem  Configuration
rem =========================

set "FFMPEG=ffmpeg"
set "INPUT_MASK=*.mp4"
set "OUT_DIR=compressed"

rem Video codec
rem   CPU / software:  libx264, libsvtav1
rem   NVIDIA NVENC:    h264_nvenc, av1_nvenc
set "VIDEO_CODEC=av1_nvenc"

rem Quality target (integer)
rem   This single variable is reused across encoders.
rem
rem   libx264:
rem     Accepts roughly 0–51.
rem     Lower = higher quality / larger files.
rem     Typical guidance:
rem       18–20 high quality, 21–23 balanced, 24–28 smaller.
rem
rem   libsvtav1:
rem     Accepts roughly 0–63.
rem     Lower = higher quality / larger files.
rem     Typical guidance:
rem       20–28 high quality, 29–35 balanced, 36+ smaller.
rem
rem   h264_nvenc / av1_nvenc:
rem     This value is used as -cq in VBR mode (CRF-like behavior).
rem     Lower = higher quality / higher bitrate.
rem     Typical guidance:
rem       19–22 high quality, 23–28 balanced, 29+ smaller.
rem
rem   Extreme values will either bloat files (very low) or add visible artifacts (very high).
rem   Values outside an encoder’s supported range may be rejected or clamped by ffmpeg.
set "CRF=23"

rem 0 = skip existing outputs, 1 = overwrite outputs
set "OVERWRITE_EXISTING=1"

rem Cropping
set "ENABLE_CROP=1"
set "CROP_EXPR=crop=1538:1538:1455:1505"

rem Scaling
set "ENABLE_SCALE=1"
set "SCALE_EXPR=scale=1500:1500"

rem Rotation:
rem   0 = none
rem   1 = 90° clockwise  (transpose=1)
rem   2 = 90° counterclockwise (transpose=2)
rem   3 = 180° (transpose=1,transpose=1)
set "ROTATE_MODE=0"

rem Rule-of-thumb denoise/sharpen
set "DENOISE=1"
set "SHARPEN=1"

rem Concatenation
set "ENABLE_CONCAT=1"
set "CONCAT_OUTPUT_NAME=all_merged.mp4"

rem MP4 usability
set "FASTSTART=1"

rem Audio robustness
rem   0 = never fallback
rem   1 = retry encode with AAC if audio copy fails
set "AUDIO_FALLBACK_AAC=1"
set "AUDIO_BITRATE=160k"

rem Logging
set "LOGLEVEL=error"


rem =========================
rem  Pre-flight
rem =========================

set "BASE_DIR=%CD%"

where "%FFMPEG%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: "%FFMPEG%" not found on PATH.
    goto :EOF
)

rem -------------------------
rem Estimate target dimensions (for denoise/sharpen heuristics)
rem -------------------------

set "TARGET_W="
set "TARGET_H="
set "TARGET_MAX=0"

rem Prefer SCALE dimensions when numeric (scale=W:H)
if "%ENABLE_SCALE%"=="1" (
    set "SCALE_DIMS="
    for /f "tokens=2 delims==" %%A in ("!SCALE_EXPR!") do set "SCALE_DIMS=%%A"
    for /f "tokens=1,2 delims=:" %%W in ("!SCALE_DIMS!") do (
        set "TARGET_W=%%W"
        set "TARGET_H=%%X"
    )
)

rem Fallback to CROP dimensions (crop=W:H:...)
if not defined TARGET_W if "%ENABLE_CROP%"=="1" (
    set "CROP_DIMS="
    for /f "tokens=2 delims==" %%A in ("!CROP_EXPR!") do set "CROP_DIMS=%%A"
    for /f "tokens=1,2 delims=:" %%W in ("!CROP_DIMS!") do (
        set "TARGET_W=%%W"
        set "TARGET_H=%%X"
    )
)

rem Validate numeric TARGET_W/TARGET_H
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
    if defined TARGET_H (
        if !TARGET_H! GTR !TARGET_MAX! set "TARGET_MAX=!TARGET_H!"
    )
)

rem Compute display dimensions (account for 90° rotation)
set "DISPLAY_W=!TARGET_W!"
set "DISPLAY_H=!TARGET_H!"
if "%ROTATE_MODE%"=="1" (
    if defined TARGET_W if defined TARGET_H (
        set "DISPLAY_W=!TARGET_H!"
        set "DISPLAY_H=!TARGET_W!"
    )
)
if "%ROTATE_MODE%"=="2" (
    if defined TARGET_W if defined TARGET_H (
        set "DISPLAY_W=!TARGET_H!"
        set "DISPLAY_H=!TARGET_W!"
    )
)

rem -------------------------
rem Choose rule-of-thumb filters
rem -------------------------

set "DENOISE_FILTER=hqdn3d=3.0:2.0:4.0:4.0"
set "SHARPEN_FILTER=unsharp=5:5:0.8:5:5:0.0"

rem Buckets by max dimension:
rem   <=1250  -> ~1000 profile
rem   <=1750  -> ~1500 profile
rem   <=2250  -> ~2000 profile
rem   >2250   -> ~2500–3000 profile
if !TARGET_MAX! GTR 0 (
    if !TARGET_MAX! LEQ 1250 (
        set "DENOISE_FILTER=hqdn3d=2.3:1.5:3.0:3.0"
        set "SHARPEN_FILTER=unsharp=3:3:0.7:3:3:0.0"
    ) else if !TARGET_MAX! LEQ 1750 (
        set "DENOISE_FILTER=hqdn3d=3.0:2.0:4.0:4.0"
        set "SHARPEN_FILTER=unsharp=5:5:0.8:5:5:0.0"
    ) else if !TARGET_MAX! LEQ 2250 (
        set "DENOISE_FILTER=hqdn3d=3.7:2.4:4.9:4.9"
        set "SHARPEN_FILTER=unsharp=7:7:0.87:7:7:0.0"
    ) else (
        set "DENOISE_FILTER=hqdn3d=4.4:3.0:5.9:5.9"
        set "SHARPEN_FILTER=unsharp=9:9:0.97:9:9:0.0"
    )
)

rem -------------------------
rem Rotation filter selection
rem -------------------------

set "ROTATE_FILTER="
if "%ROTATE_MODE%"=="1" set "ROTATE_FILTER=transpose=1"
if "%ROTATE_MODE%"=="2" set "ROTATE_FILTER=transpose=2"
if "%ROTATE_MODE%"=="3" set "ROTATE_FILTER=transpose=1,transpose=1"

rem -------------------------
rem Build video filter chain
rem -------------------------

set "VF_ARGS="

rem 1) crop
if "%ENABLE_CROP%"=="1" (
    set "VF_ARGS=!CROP_EXPR!"
)

rem 2) scale
if "%ENABLE_SCALE%"=="1" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!SCALE_EXPR!"
    ) else (
        set "VF_ARGS=!SCALE_EXPR!"
    )
)

rem 3) rotate (after crop/scale)
if not "%ROTATE_MODE%"=="0" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!ROTATE_FILTER!"
    ) else (
        set "VF_ARGS=!ROTATE_FILTER!"
    )
)

rem 4) denoise
if "%DENOISE%"=="1" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!DENOISE_FILTER!"
    ) else (
        set "VF_ARGS=!DENOISE_FILTER!"
    )
)

rem 5) sharpen
if "%SHARPEN%"=="1" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!SHARPEN_FILTER!"
    ) else (
        set "VF_ARGS=!SHARPEN_FILTER!"
    )
)

set "VF_SWITCH="
if defined VF_ARGS (
    set "VF_SWITCH=-vf !VF_ARGS!"
)

rem -------------------------
rem Detect CUDA hwaccel availability
rem -------------------------

set "CUDA_AVAILABLE="
for /f "delims=" %%H in ('"%FFMPEG%" -hide_banner -hwaccels 2^>nul ^| findstr /I "cuda"') do (
    set "CUDA_AVAILABLE=1"
)

rem Build hwaccel args
rem NOTE: Forcing GPU frame output breaks CPU filter chains.
rem       Therefore:
rem         - If CUDA is available AND no -vf filters are set:
rem             enable: -hwaccel cuda -hwaccel_output_format cuda
rem         - If CUDA is available AND filters are set:
rem             enable decode-only: -hwaccel cuda
set "HWACCEL_ARGS="
if defined CUDA_AVAILABLE (
    if not defined VF_ARGS (
        set "HWACCEL_ARGS=-hwaccel cuda -hwaccel_output_format cuda"
    ) else (
        set "HWACCEL_ARGS=-hwaccel cuda"
    )
)

rem -------------------------
rem Build codec-specific encoding arguments
rem -------------------------

set "VENC_ARGS="

if /I "%VIDEO_CODEC%"=="libx264" (
    set "VENC_ARGS=-c:v libx264 -crf %CRF% -preset slow"
) else if /I "%VIDEO_CODEC%"=="libsvtav1" (
    rem SVT-AV1 preset: lower = slower/better. 6 is a reasonable default.
    set "VENC_ARGS=-c:v libsvtav1 -crf %CRF% -preset 6"
) else if /I "%VIDEO_CODEC%"=="h264_nvenc" (
    set "VENC_ARGS=-c:v h264_nvenc -preset p6 -tune hq -rc vbr -cq %CRF% -b:v 0"
) else if /I "%VIDEO_CODEC%"=="av1_nvenc" (
    set "VENC_ARGS=-c:v av1_nvenc -preset p6 -tune hq -rc vbr -cq %CRF% -b:v 0"
) else (
    rem Fallback: assume encoder supports -crf
    set "VENC_ARGS=-c:v %VIDEO_CODEC% -crf %CRF%"
)

rem -------------------------
rem Input discovery
rem -------------------------

set "TOTAL=0"
for /f "delims=" %%F in ('dir /b /a-d "%INPUT_MASK%" 2^>nul') do (
    set /a TOTAL+=1
)

if %TOTAL% LEQ 0 (
    echo No files matching "%INPUT_MASK%" found in "%BASE_DIR%".
    goto :EOF
)

rem -------------------------
rem Output directory + concat list
rem -------------------------

if not exist "%OUT_DIR%\" (
    mkdir "%OUT_DIR%" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Failed to create output directory "%OUT_DIR%".
        goto :EOF
    )
)

rem Concat list lives inside OUT_DIR.
rem Paths written are relative to OUT_DIR to keep the list simple.
rem Note: filenames containing single quotes may still break concat list syntax.
set "CONCAT_LIST=%OUT_DIR%\_concat_list.txt"
if "%ENABLE_CONCAT%"=="1" (
    if exist "%CONCAT_LIST%" del /f /q "%CONCAT_LIST%" >nul 2>&1
)

echo --- MP4 batch compression ---
echo Current directory: "%BASE_DIR%"
echo Input mask: "%INPUT_MASK%"
echo Output directory: "%OUT_DIR%"
echo Video codec: %VIDEO_CODEC%
echo Quality (CRF/CQ): %CRF%
echo ROTATE_MODE: %ROTATE_MODE%
if defined DISPLAY_W (
    if defined DISPLAY_H (
        echo Estimated target size (post-rotate): !DISPLAY_W!x!DISPLAY_H!
    ) else (
        echo Estimated target width: !DISPLAY_W!
    )
) else (
    echo Estimated target size: unknown ^(using ~1500 profile for denoise/sharpen^)
)
echo DENOISE=%DENOISE%  ^|  Filter: !DENOISE_FILTER!
echo SHARPEN=%SHARPEN% ^|  Filter: !SHARPEN_FILTER!
echo Video filters: %VF_SWITCH%
if defined CUDA_AVAILABLE (
    echo CUDA hwaccel: available
    echo HWACCEL args: %HWACCEL_ARGS%
) else (
    echo CUDA hwaccel: not detected
)
echo Video encode args: %VENC_ARGS%
echo FASTSTART=%FASTSTART%
echo AUDIO_FALLBACK_AAC=%AUDIO_FALLBACK_AAC%
echo.

if /I not "%VIDEO_CODEC%"=="libx264" ^
if /I not "%VIDEO_CODEC%"=="libsvtav1" ^
if /I not "%VIDEO_CODEC%"=="h264_nvenc" ^
if /I not "%VIDEO_CODEC%"=="av1_nvenc" (
    echo WARNING: VIDEO_CODEC "%VIDEO_CODEC%" is not a known preset in this script.
    echo          Script will pass it as-is with a default -crf tail.
    echo.
)

echo Found %TOTAL% file^(s^) to process.
echo.

rem =========================
rem  Main loop
rem =========================

set "DONE=0"
set "FAILED=0"
set "SKIPPED=0"

rem Using dir /b + subroutine reduces delayed-expansion filename hazards.
for /f "delims=" %%F in ('dir /b /a-d "%INPUT_MASK%" 2^>nul') do (
    call :PROCESS_ONE "%%F"
)

rem =========================
rem  Concatenation step
rem =========================

if "%ENABLE_CONCAT%"=="1" (
    if %DONE% GTR 0 (
        if exist "%CONCAT_LIST%" (
            echo Concatenating %DONE% file^(s^) into "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"...
            "%FFMPEG%" -y -hide_banner -loglevel %LOGLEVEL% -err_detect ignore_err ^
                -f concat -safe 0 -i "%CONCAT_LIST%" -c copy "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"
            if errorlevel 1 (
                echo   ERROR: ffmpeg failed during concatenation.
            ) else (
                echo   Concatenation OK.
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
if "%ENABLE_CONCAT%"=="1" (
    echo   Concatenated   : "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"
)
echo   Output folder    : "%OUT_DIR%"
echo.

pause
endlocal
goto :EOF


rem =========================
rem  Per-file worker
rem =========================
:PROCESS_ONE

rem Minimize delayed-expansion exposure to filenames.
setlocal EnableExtensions DisableDelayedExpansion

set "IN_FILE=%~1"
set "BASENAME=%~n1"
set "OUT_PATH=%OUT_DIR%\%BASENAME%.mp4"

if exist "%OUT_PATH%" (
    if "%OVERWRITE_EXISTING%"=="0" (
        echo Skipping "%IN_FILE%"  ^>  "%OUT_PATH%"  ^(already exists, OVERWRITE_EXISTING=0^)
        endlocal & set /a SKIPPED+=1
        echo.
        goto :EOF
    ) else (
        echo Overwriting existing output for "%IN_FILE%"  ^>  "%OUT_PATH%"
    )
) else (
    echo Compressing "%IN_FILE%"  ^>  "%OUT_PATH%"
)

set "MOVFLAGS="
if "%FASTSTART%"=="1" set "MOVFLAGS=-movflags +faststart"

rem Primary attempt: copy audio.
"%FFMPEG%" -y -hide_banner -loglevel %LOGLEVEL% -err_detect ignore_err ^
    %HWACCEL_ARGS% ^
    -i "%IN_FILE%" ^
    %VENC_ARGS% %VF_SWITCH% %MOVFLAGS% -c:a copy ^
    "%OUT_PATH%"

if errorlevel 1 (
    if "%AUDIO_FALLBACK_AAC%"=="1" (
        echo   Retrying with AAC audio...
        "%FFMPEG%" -y -hide_banner -loglevel %LOGLEVEL% -err_detect ignore_err ^
            %HWACCEL_ARGS% ^
            -i "%IN_FILE%" ^
            %VENC_ARGS% %VF_SWITCH% %MOVFLAGS% -c:a aac -b:a %AUDIO_BITRATE% ^
            "%OUT_PATH%"
    )
)

if errorlevel 1 (
    echo   ERROR: ffmpeg failed for "%IN_FILE%".
    endlocal & set /a FAILED+=1
) else (
    echo   OK
    if "%ENABLE_CONCAT%"=="1" (
        rem Write basename-only path relative to OUT_DIR list location.
        >>"%CONCAT_LIST%" echo file '%BASENAME%.mp4'
    )
    endlocal & set /a DONE+=1
)

echo.
goto :EOF
