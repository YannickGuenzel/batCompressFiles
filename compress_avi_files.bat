:: ======================================================================
:: COMPRESS_AVI_FILES.BAT
:: ----------------------------------------------------------------------
:: Purpose:
::   Batch-compress .avi files in the current directory using ffmpeg,
::   with optional cropping, scaling, rule-of-thumb denoise/sharpen,
::   and optional concatenation of outputs.
::
:: Behavior:
::   - Scans the current directory for files matching INPUT_MASK (default: *.avi).
::   - Encodes each file into OUT_DIR using a selectable video codec.
::   - Applies codec-appropriate quality flags automatically:
::       * libx264 / libsvtav1  -> -crf
::       * h264_nvenc / av1_nvenc -> -rc vbr -cq (CRF variable reused as CQ target)
::   - Builds a -vf filter chain from enabled stages:
::       crop -> scale -> denoise -> sharpen
::   - Denoise/sharpen use rule-of-thumb parameters based on the
::     estimated output dimensions.
::   - Optionally concatenates all successfully processed outputs into one file
::     using ffmpeg’s concat demuxer (stream copy, no re-encode).
::   - Attempts to enable CUDA hardware decode when available.
::       * IMPORTANT: Forcing GPU output frames (-hwaccel_output_format cuda)
::         conflicts with CPU-only filters (crop/scale/hqdn3d/unsharp).
::         This script enables that flag only when no -vf filters are set.
::
:: Configuration (edit in "Configuration" section below):
::   - FFMPEG              : ffmpeg executable name or full path.
::   - INPUT_MASK          : glob for input files (e.g. *.avi).
::   - OUT_DIR             : output directory (relative to script directory).
::   - VIDEO_CODEC         : libx264, libsvtav1, h264_nvenc, av1_nvenc, or other ffmpeg encoder name.
::   - CRF                 : quality target (see detailed ranges below).
::   - OVERWRITE_EXISTING  : 0 = skip existing outputs, 1 = overwrite them.
::   - ENABLE_CROP         : 0 = no crop, 1 = apply CROP_EXPR.
::   - CROP_EXPR           : ffmpeg crop expression (e.g. crop=1280:720:0:0).
::   - ENABLE_SCALE        : 0 = no scale, 1 = apply SCALE_EXPR.
::   - SCALE_EXPR          : ffmpeg scale expression (e.g. scale=1280:-1).
::   - DENOISE             : 0 = no denoise, 1 = add hqdn3d rule-of-thumb.
::   - SHARPEN             : 0 = no sharpen, 1 = add unsharp rule-of-thumb.
::   - ENABLE_CONCAT       : 0 = no concat, 1 = concat all successful outputs.
::   - CONCAT_OUTPUT_NAME  : final concatenated file name inside OUT_DIR.
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
:: Estimation logic:
::   - If ENABLE_SCALE=1 and SCALE_EXPR is numeric (scale=W:H), use W/H.
::   - Else if ENABLE_CROP=1, use crop W/H from CROP_EXPR.
::   - Else fall back to the 1500×1500 profile.
::
:: Output:
::   - Individual encoded files in OUT_DIR, one per input file.
::   - Optional concatenated file OUT_DIR\CONCAT_OUTPUT_NAME when ENABLE_CONCAT=1.
::   - Temporary concat list file _concat_list.txt in the script directory
::     when concatenation is enabled.
:: ======================================================================

@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem =========================
rem  Configuration
rem =========================

rem ffmpeg executable name or full path
set "FFMPEG=ffmpeg"

rem Input pattern
set "INPUT_MASK=*.avi"

rem Output directory
set "OUT_DIR=compressed"

rem Video codec: choose between valid encoder options
rem   CPU / software:  libx264, libsvtav1
rem   NVIDIA NVENC:    h264_nvenc, av1_nvenc
set "VIDEO_CODEC=av1_nvenc"

rem Quality target (integer)
rem   This single variable is reused across encoders.
rem --- libx264:
rem     Accepts roughly 0–51.
rem     Lower = higher quality / larger files.
rem     Typical guidance:
rem       18–20 high quality, 21–23 balanced, 24–28 smaller.
rem --- libsvtav1:
rem     Accepts roughly 0–63.
rem     Lower = higher quality / larger files.
rem     Typical guidance:
rem       20–28 high quality, 29–35 balanced, 36+ smaller.
rem --- h264_nvenc / av1_nvenc:
rem     This value is used as -cq in VBR mode (CRF-like behavior).
rem     Lower = higher quality / higher bitrate.
rem     Typical guidance:
rem       19–22 high quality, 23–28 balanced, 29+ smaller.
set "CRF=23"

rem Overwrite behavior: 0 = skip existing outputs, 1 = overwrite (default)
set "OVERWRITE_EXISTING=1"

rem --- Cropping and scaling options ---
rem Defaults: no crop, no scale
rem 
rem Common examples:
rem   CROP_EXPR=crop=1280:720:0:0          -> 1280x720 crop from top-left
rem   CROP_EXPR=crop=iw:ih-80:0:40         -> remove 40px bars top/bottom
rem   SCALE_EXPR=scale=1280:-1             -> width=1280, preserve aspect
rem   SCALE_EXPR=scale=-1:720              -> height=720, preserve aspect
rem   Rule-of-thumb denoise/sharpen assume numeric W:H for best matching.

rem Enable/disable cropping
set "ENABLE_CROP=0"
set "CROP_EXPR=crop=width:height:x:y"

rem Enable/disable scaling
set "ENABLE_SCALE=0"
set "SCALE_EXPR=scale=width:height"

rem Enable/disable rule-of-thumb denoise/sharpen
set "DENOISE=0"
set "SHARPEN=0"

rem --- Concatenation options ---
rem Enable/disable concatenation of all successfully processed outputs
set "ENABLE_CONCAT=0"
rem Output file name inside OUT_DIR
set "CONCAT_OUTPUT_NAME=all_merged.avi"


rem =========================
rem  Pre-flight checks
rem =========================

set "BASE_DIR=%CD%"
set "CONCAT_LIST=%BASE_DIR%\_concat_list.txt"

if "%ENABLE_CONCAT%"=="1" (
    if exist "%CONCAT_LIST%" del /f /q "%CONCAT_LIST%" >nul 2>&1
)

rem Check ffmpeg availability early (needed for CUDA detection)
where "%FFMPEG%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: "%FFMPEG%" not found on PATH.
    echo Install ffmpeg or update the FFMPEG variable at the top of this script.
    goto :EOF
)

rem -------------------------
rem Estimate target dimensions
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

rem Compute TARGET_MAX
if defined TARGET_W (
    set "TARGET_MAX=!TARGET_W!"
    if defined TARGET_H (
        if !TARGET_H! GTR !TARGET_MAX! set "TARGET_MAX=!TARGET_H!"
    )
)

rem -------------------------
rem Choose rule-of-thumb filters
rem -------------------------

set "DENOISE_FILTER="
set "SHARPEN_FILTER="

rem Default profile if unknown size
set "DENOISE_FILTER=hqdn3d=3.0:2.0:4.0:4.0"
set "SHARPEN_FILTER=unsharp=5:5:0.8:5:5:0.0"

rem Size buckets by max dimension:
rem   <=1250  -> ~1000 profile
rem   <=1750  -> ~1500 profile
rem   <=2250  -> ~2000 profile
rem   >2250   -> ~2500–3000 profile (midpoint settings)
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
rem Build video filter chain
rem -------------------------

set "VF_ARGS="

if "%ENABLE_CROP%"=="1" (
    set "VF_ARGS=!CROP_EXPR!"
)

if "%ENABLE_SCALE%"=="1" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!SCALE_EXPR!"
    ) else (
        set "VF_ARGS=!SCALE_EXPR!"
    )
)

if "%DENOISE%"=="1" (
    if defined VF_ARGS (
        set "VF_ARGS=!VF_ARGS!,!DENOISE_FILTER!"
    ) else (
        set "VF_ARGS=!DENOISE_FILTER!"
    )
)

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
rem Build codec-specific video encoding arguments
rem -------------------------

set "VENC_ARGS="

if /I "%VIDEO_CODEC%"=="libx264" (
    set "VENC_ARGS=-c:v libx264 -crf %CRF% -preset slow"
) else (
    if /I "%VIDEO_CODEC%"=="libsvtav1" (
        rem SVT-AV1 preset: lower = slower/better. 6 is a reasonable default.
        set "VENC_ARGS=-c:v libsvtav1 -crf %CRF% -preset 6"
    ) else (
        if /I "%VIDEO_CODEC%"=="h264_nvenc" (
            set "VENC_ARGS=-c:v h264_nvenc -preset p6 -tune hq -rc vbr -cq %CRF% -b:v 0"
        ) else (
            if /I "%VIDEO_CODEC%"=="av1_nvenc" (
                set "VENC_ARGS=-c:v av1_nvenc -preset p6 -tune hq -rc vbr -cq %CRF% -b:v 0"
            ) else (
                rem Fallback: assume encoder supports -crf
                set "VENC_ARGS=-c:v %VIDEO_CODEC% -crf %CRF%"
            )
        )
    )
)

echo --- avi batch compression ---
echo Current directory: "%BASE_DIR%"
echo Input mask: "%INPUT_MASK%"
echo Output directory: "%OUT_DIR%"
echo Video codec: %VIDEO_CODEC%
echo Quality (CRF/CQ): %CRF%
if defined TARGET_W (
    echo Estimated target size: !TARGET_W!x!TARGET_H!
) else (
    echo Estimated target size: unknown ^(using default ~1500 profile for denoise/sharpen^)
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
echo.

rem Basic codec sanity check
if /I not "%VIDEO_CODEC%"=="libx264" ^
if /I not "%VIDEO_CODEC%"=="libsvtav1" ^
if /I not "%VIDEO_CODEC%"=="h264_nvenc" ^
if /I not "%VIDEO_CODEC%"=="av1_nvenc" (
    echo WARNING: VIDEO_CODEC "%VIDEO_CODEC%" is not a known preset in this script.
    echo          Script will pass it as-is to ffmpeg with a default -crf tail.
)

rem Check for input files
if not exist %INPUT_MASK% (
    echo No files matching "%INPUT_MASK%" found in "%BASE_DIR%".
    goto :EOF
)

rem Create output directory if needed
if not exist "%OUT_DIR%\" (
    mkdir "%OUT_DIR%" >nul 2>&1
    if errorlevel 1 (
        echo ERROR: Failed to create output directory "%OUT_DIR%".
        goto :EOF
    )
)

rem Count candidate files
set "TOTAL=0"
for %%F in (%INPUT_MASK%) do (
    set /a TOTAL+=1
)

echo Found %TOTAL% file^(s^) to process.
echo.


rem =========================
rem  Main loop
rem =========================

set "DONE=0"
set "FAILED=0"
set "SKIPPED=0"

for %%F in (%INPUT_MASK%) do (
    set "BASENAME=%%~nF"
    set "OUT_PATH=%OUT_DIR%\!BASENAME!.avi"

    set "DO_SKIP=0"

    if exist "!OUT_PATH!" (
        if "%OVERWRITE_EXISTING%"=="0" (
            echo Skipping "%%F"  ^>  "!OUT_PATH!"  ^(already exists, OVERWRITE_EXISTING=0^)
            set "DO_SKIP=1"
            set /a SKIPPED+=1
        ) else (
            echo Overwriting existing output for "%%F"  ^>  "!OUT_PATH!"
        )
    ) else (
        echo Compressing "%%F"  ^>  "!OUT_PATH!"
    )

    if "!DO_SKIP!"=="1" (
        rem skip this file
    ) else (
        "%FFMPEG%" -y -hide_banner -loglevel error -err_detect ignore_err ^
            %HWACCEL_ARGS% ^
            -i "%%F" ^
            !VENC_ARGS! %VF_SWITCH% -c:a copy ^
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
            )
        )
    )

    echo.
)

rem =========================
rem  Concatenation step
rem =========================

if "%ENABLE_CONCAT%"=="1" (
    if !DONE! GTR 0 (
        if exist "%CONCAT_LIST%" (
            echo Concatenating !DONE! file^(s^) into "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"...
            "%FFMPEG%" -y -hide_banner -loglevel error -err_detect ignore_err -f concat -safe 0 -i "%CONCAT_LIST%" -c copy "%OUT_DIR%\%CONCAT_OUTPUT_NAME%"
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
