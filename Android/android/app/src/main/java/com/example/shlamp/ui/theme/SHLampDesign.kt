package com.example.shlamp.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Smart Handicrafts® visual language.
 *
 * The palette is intentionally bright, calm and appliance-focused: pale blue
 * backgrounds, clean white cards, a teal primary action and small warm accents
 * for light output. Keeping these tokens central lets the account, setup,
 * control, care and settings screens feel like one product.
 */
object SHLampDesign {
    val Background = Color(0xFFF3F6FA)
    val BackgroundTop = Color(0xFFE8F7FA)
    val BackgroundBottom = Color(0xFFF7F8FC)

    val Surface = Color(0xFFFFFFFF)
    val SurfaceRaised = Color(0xFFFAFCFE)
    val SurfaceSoft = Color(0xFFEEF3F7)
    val SurfaceTint = Color(0xFFEAF8FA)
    val Border = Color(0xFFDCE4EB)
    val Divider = Color(0xFFE8EDF2)
    val Shadow = Color(0x1A1D2939)

    val TextPrimary = Color(0xFF182230)
    val TextSecondary = Color(0xFF667085)
    val TextDisabled = Color(0xFF98A2B3)

    val Primary = Color(0xFF078CA4)
    val OnPrimary = Color(0xFFFFFFFF)
    val PrimarySoft = Color(0xFFDDF5F7)
    val PrimaryDeep = Color(0xFF086A7B)

    val Secondary = Color(0xFF6E63E8)
    val OnSecondary = Color(0xFFFFFFFF)
    val SecondarySoft = Color(0xFFEFEDFF)

    val Warm = Color(0xFFFFB74D)
    val WarmDeep = Color(0xFFE88E18)
    val WarmSoft = Color(0xFFFFF3D8)
    val Success = Color(0xFF24A36F)
    val SuccessSoft = Color(0xFFE1F5EC)
    val Error = Color(0xFFD94B55)
    val ErrorSoft = Color(0xFFFFE9EB)
    val Warning = Color(0xFFE68A16)
    val WarningSoft = Color(0xFFFFF1DC)
    val Info = Color(0xFF3276D8)
    val InfoSoft = Color(0xFFE7F0FF)
    val Offline = Color(0xFF98A2B3)

    val ScreenShape = RoundedCornerShape(30.dp)
    val CardShape = RoundedCornerShape(24.dp)
    val ControlShape = RoundedCornerShape(18.dp)
    val SmallShape = RoundedCornerShape(14.dp)
}
