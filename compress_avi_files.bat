:: ======================================================================
:: COMPRESS_AVI_FILES.BAT
:: ----------------------------------------------------------------------
:: Purpose:
::   Batch-compress .avi files in the current directory using ffmpeg,
::   with optional cropping, scaling, and final concatenation of outputs.
::
:: Behavior:
::   - Scans the current directory for files matching INPUT_MASK (default: *.avi).
::   - Encodes each file into OUT_DIR using a selectable video codec
::     (libx264 or libsvtav1) with fixed CRF.
::   - Optionally applies cropping and/or scaling via a -vf filter chain.
::   - Optionally concatenates all successfully processed outputs into one file
::     using ffmpeg’s concat demuxer (stream copy, no re-encode).
::
:: Configuration (edit in "Configuration" section below):
::   - FFMPEG              : ffmpeg executable name or full path.
::   - INPUT_MASK          : glob for input files (e.g. *.avi).
::   - OUT_DIR             : output directory (relative to script directory).
::   - VIDEO_CODEC         : libsvtav1 (default, slow but better compression) or libx264.
::   - CRF                 : constant rate factor (codec-dependent scale).
::   - OVERWRITE_EXISTING  : 0 = skip existing outputs, 1 = overwrite them.
::   - ENABLE_CROP         : 0 = no crop, 1 = apply CROP_EXPR.
::   - CROP_EXPR           : ffmpeg crop expression (e.g. crop=1280:720:0:0).
::   - ENABLE_SCALE        : 0 = no scale, 1 = apply SCALE_EXPR.
::   - SCALE_EXPR          : ffmpeg scale expression (e.g. scale=1280:-1).
::   - ENABLE_CONCAT       : 0 = no concat, 1 = concat all successful outputs.
::   - CONCAT_OUTPUT_NAME  : final concatenated file name inside OUT_DIR.
::
:: Output:
::   - Individual encoded files in OUT_DIR, one per input file.
::   - Optional concatenated file OUT_DIR\CONCAT_OUTPUT_NAME when ENABLE_CONCAT=1.
::   - Temporary concat list file _concat_list.txt in the script directory
::     when concatenation is enabled.
::
:: Requirements:
::   - ffmpeg built with the chosen VIDEO_CODEC (libx264 or libsvtav1) and
::     resolvable via PATH or FFMPEG set to full path.
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

rem Video codec: choose between valid encoder options (e.g., libsvtav1 and libx264 (CPU / software encoders) or h264_nvenc and av1_nvenc (GPU / hardware encoders – NVIDIA)
set "VIDEO_CODEC=av1_nvenc"

rem Quality settings
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

rem Enable/disable cropping
set "ENABLE_CROP=1"
set "CROP_EXPR=crop=1538:1538:1455:1505"

rem Enable/disable scaling
set "ENABLE_SCALE=1"
set "SCALE_EXPR=scale=1500:1500"

rem --- Concatenation options ---
rem Enable/disable concatenation of all successfully processed outputs
set "ENABLE_CONCAT=1"
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

echo --- avi batch compression ---
echo Current directory: "%BASE_DIR%"
echo Input mask: "%INPUT_MASK%"
echo Output directory: "%OUT_DIR%"
echo Video codec: %VIDEO_CODEC%
echo CRF: %CRF%
echo.

rem Basic codec sanity check
if /I not "%VIDEO_CODEC%"=="libx264" if /I not "%VIDEO_CODEC%"=="libsvtav1" (
    echo WARNING: VIDEO_CODEC "%VIDEO_CODEC%" is not "libx264" or "libsvtav1".
    echo          Script will pass it as-is to ffmpeg. Expect failure if invalid.
)

rem Build video filter chain based on configuration
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
set "VF_SWITCH="
if defined VF_ARGS (
    set "VF_SWITCH=-vf !VF_ARGS!"
)

echo Video filters: %VF_SWITCH%
echo.

rem Check ffmpeg availability
where "%FFMPEG%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: "%FFMPEG%" not found on PATH.
    echo Install ffmpeg or update the FFMPEG variable at the top of this script.
    goto :EOF
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
    rem %%F = "filename.ext"
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
            -i "%%F" ^
            -c:v %VIDEO_CODEC% -crf %CRF% %VF_SWITCH% -c:a copy ^
            "!OUT_PATH!"

        if errorlevel 1 (
            echo   ERROR: ffmpeg failed for "%%F".
            set /a FAILED+=1
        ) else (
            echo   OK
            set /a DONE+=1

            if "%ENABLE_CONCAT%"=="1" (
                rem Build absolute path for concat list
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
