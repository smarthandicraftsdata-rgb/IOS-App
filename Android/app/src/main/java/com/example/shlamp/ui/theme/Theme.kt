package com.example.shlamp.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val LampColorScheme = lightColorScheme(
    primary = SHLampDesign.Primary,
    onPrimary = SHLampDesign.OnPrimary,
    primaryContainer = SHLampDesign.PrimarySoft,
    onPrimaryContainer = SHLampDesign.PrimaryDeep,
    secondary = SHLampDesign.Secondary,
    onSecondary = SHLampDesign.OnSecondary,
    secondaryContainer = SHLampDesign.SecondarySoft,
    onSecondaryContainer = SHLampDesign.TextPrimary,
    tertiary = SHLampDesign.Warm,
    onTertiary = SHLampDesign.TextPrimary,
    background = SHLampDesign.Background,
    onBackground = SHLampDesign.TextPrimary,
    surface = SHLampDesign.Surface,
    onSurface = SHLampDesign.TextPrimary,
    surfaceVariant = SHLampDesign.SurfaceSoft,
    onSurfaceVariant = SHLampDesign.TextSecondary,
    outline = SHLampDesign.Border,
    outlineVariant = SHLampDesign.Divider,
    error = SHLampDesign.Error,
    onError = SHLampDesign.OnPrimary,
    errorContainer = SHLampDesign.ErrorSoft,
    onErrorContainer = SHLampDesign.Error
)

private val LampShapes = Shapes(
    extraSmall = SHLampDesign.SmallShape,
    small = SHLampDesign.SmallShape,
    medium = SHLampDesign.ControlShape,
    large = SHLampDesign.CardShape,
    extraLarge = SHLampDesign.ScreenShape
)

@Composable
fun SHLAMPTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = LampColorScheme,
        typography = Typography,
        shapes = LampShapes,
        content = content
    )
}
