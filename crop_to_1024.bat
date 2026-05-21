@echo off
setlocal

if "%~1"=="" (
    echo Drag one or more image files onto this batch file.
    echo.
    pause
    exit /b 1
)

set "CROP_BATCH_FILE=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$path = $env:CROP_BATCH_FILE; $text = [System.IO.File]::ReadAllText($path); $marker = '# POWERSHELL_START'; $index = $text.LastIndexOf($marker); if ($index -lt 0) { throw 'PowerShell script marker was not found.' }; $code = $text.Substring($index + $marker.Length); & ([scriptblock]::Create($code)) @args" %*
set "exitCode=%ERRORLEVEL%"
echo.
pause
exit /b %exitCode%

# POWERSHELL_START
Add-Type -AssemblyName System.Drawing

function Read-Integer {
    param([string]$Message)

    while ($true) {
        $value = Read-Host $Message
        $number = 0
        if ([int]::TryParse($value, [ref]$number) -and $number -ge 0) {
            return $number
        }
        Write-Host "Please enter a non-negative integer."
    }
}

function Get-ImageFormat {
    param([string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        ".jpg" { return [System.Drawing.Imaging.ImageFormat]::Jpeg }
        ".jpeg" { return [System.Drawing.Imaging.ImageFormat]::Jpeg }
        ".png" { return [System.Drawing.Imaging.ImageFormat]::Png }
        ".bmp" { return [System.Drawing.Imaging.ImageFormat]::Bmp }
        ".gif" { return [System.Drawing.Imaging.ImageFormat]::Gif }
        ".tif" { return [System.Drawing.Imaging.ImageFormat]::Tiff }
        ".tiff" { return [System.Drawing.Imaging.ImageFormat]::Tiff }
        default { return $null }
    }
}

function Save-Image {
    param(
        [System.Drawing.Bitmap]$Image,
        [string]$Path,
        [System.Drawing.Imaging.ImageFormat]$Format
    )

    if ($Format.Guid -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid) {
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.FormatID -eq $Format.Guid }
        $parameters = New-Object System.Drawing.Imaging.EncoderParameters 1
        $parameters.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 95L
        $Image.Save($Path, $codec, $parameters)
        $parameters.Dispose()
        return
    }

    $Image.Save($Path, $Format)
}

function Apply-Orientation {
    param([System.Drawing.Image]$Image)

    $orientationId = 274
    if ($Image.PropertyIdList -notcontains $orientationId) {
        return
    }

    $orientation = [BitConverter]::ToUInt16($Image.GetPropertyItem($orientationId).Value, 0)
    $rotateFlip = $null
    switch ($orientation) {
        2 { $rotateFlip = [System.Drawing.RotateFlipType]::RotateNoneFlipX }
        3 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate180FlipNone }
        4 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate180FlipX }
        5 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate90FlipX }
        6 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate90FlipNone }
        7 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate270FlipX }
        8 { $rotateFlip = [System.Drawing.RotateFlipType]::Rotate270FlipNone }
    }

    if ($null -ne $rotateFlip) {
        $Image.RotateFlip($rotateFlip)
        $Image.RemovePropertyItem($orientationId)
    }
}

Write-Host "Select crop mode:"
Write-Host "1. Top-right largest square, resize to 1024x1024"
Write-Host "2. Center largest square, resize to 1024x1024"
Write-Host "3. Custom start pixel, largest square, resize to 1024x1024"
Write-Host ""

do {
    $mode = Read-Host "Mode"
} while ($mode -notin @("1", "2", "3"))

$customX = 0
$customY = 0
if ($mode -eq "3") {
    $customX = Read-Integer "Start X"
    $customY = Read-Integer "Start Y"
}

foreach ($file in $args) {
    try {
        $filePath = [System.IO.Path]::GetFullPath($file)
        if (-not [System.IO.File]::Exists($filePath)) {
            Write-Host "[SKIP] Not found: $file"
            continue
        }

        $format = Get-ImageFormat $filePath
        if ($null -eq $format) {
            Write-Host "[SKIP] Unsupported extension: $filePath"
            continue
        }

        $source = [System.Drawing.Image]::FromFile($filePath)
        try {
            Apply-Orientation $source
            $size = [Math]::Min($source.Width, $source.Height)
            $x = 0
            $y = 0

            switch ($mode) {
                "1" {
                    $x = $source.Width - $size
                    $y = 0
                }
                "2" {
                    $x = [Math]::Floor(($source.Width - $size) / 2)
                    $y = [Math]::Floor(($source.Height - $size) / 2)
                }
                "3" {
                    if ($customX -ge $source.Width -or $customY -ge $source.Height) {
                        Write-Host "[SKIP] Start pixel is outside the image: $filePath"
                        continue
                    }
                    $x = $customX
                    $y = $customY
                    $size = [Math]::Min($source.Width - $x, $source.Height - $y)
                }
            }

            $target = New-Object System.Drawing.Bitmap 1024, 1024
            $temporaryOutput = $null
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($target)
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $sourceRectangle = New-Object System.Drawing.Rectangle $x, $y, $size, $size
                    $targetRectangle = New-Object System.Drawing.Rectangle 0, 0, 1024, 1024
                    $graphics.DrawImage($source, $targetRectangle, $sourceRectangle, [System.Drawing.GraphicsUnit]::Pixel)
                } finally {
                    $graphics.Dispose()
                }

                $directory = [System.IO.Path]::GetDirectoryName($filePath)
                $outputDirectory = Join-Path $directory "processed_1024"
                [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
                $output = Join-Path $outputDirectory ([System.IO.Path]::GetFileName($filePath))
                $temporaryOutput = Join-Path $outputDirectory ([System.IO.Path]::GetRandomFileName())
                Save-Image $target $temporaryOutput $format
                Move-Item -LiteralPath $temporaryOutput -Destination $output -Force
                Write-Host "[OK] $output"
            } finally {
                if ($null -ne $temporaryOutput -and [System.IO.File]::Exists($temporaryOutput)) {
                    Remove-Item -LiteralPath $temporaryOutput -Force
                }
                $target.Dispose()
            }
        } finally {
            $source.Dispose()
        }
    } catch {
        Write-Host "[FAIL] $file"
        Write-Host $_.Exception.Message
    }
}
