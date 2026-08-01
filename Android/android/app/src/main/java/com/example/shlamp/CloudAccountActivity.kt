@file:Suppress("SpellCheckingInspection")

package com.example.shlamp

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.shlamp.ui.theme.SHLampDesign
import com.example.shlamp.ui.theme.SHLAMPTheme
import java.util.concurrent.Executors

private val AccountBackground = SHLampDesign.Background
private val AccountSurface = SHLampDesign.Surface
private val AccountText = SHLampDesign.TextPrimary
private val AccountTextSecondary = SHLampDesign.TextSecondary
private val AccountAccent = SHLampDesign.Primary
private val AccountOnAccent = SHLampDesign.OnPrimary
private val AccountAccentSoft = SHLampDesign.PrimarySoft
private val AccountBorder = SHLampDesign.Border
private val AccountSuccess = SHLampDesign.Success
private val AccountSuccessSoft = SHLampDesign.SuccessSoft
private val AccountError = SHLampDesign.Error
private val AccountErrorSoft = SHLampDesign.ErrorSoft

private enum class AccountMode {
    SIGN_IN,
    CREATE_ACCOUNT,
    RESET_PASSWORD
}

class CloudAccountActivity : ComponentActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val api by lazy { CloudApiClient() }
    private val vault by lazy { CloudTokenVault(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val initialMessage = intent.getStringExtra("cloud_message").orEmpty()
        setContent {
            SHLAMPTheme {
                CloudAccountScreen(
                    initialMessage = initialMessage,
                    checkExistingSession = ::checkExistingSession,
                    signIn = ::signIn,
                    register = ::register,
                    requestPasswordReset = ::requestPasswordReset,
                    confirmPasswordReset = ::confirmPasswordReset,
                    signOut = ::signOut,
                    openCloudHome = ::openCloudHome
                )
            }
        }
    }

    private fun checkExistingSession(callback: (SessionCheck) -> Unit) {
        worker.execute {
            val stored = vault.readSession()
            if (stored == null) {
                runOnUiThread { callback(SessionCheck.SignedOut) }
                return@execute
            }

            val first = api.readMe(stored.accessToken)
            if (first.user != null) {
                runOnUiThread { callback(SessionCheck.SignedIn(first.user)) }
                return@execute
            }

            if (!first.unauthorized) {
                runOnUiThread {
                    callback(SessionCheck.Failed("We couldn't sign you in automatically."))
                }
                return@execute
            }

            val refreshed = api.refresh(stored.refreshToken)
            if (refreshed == null) {
                vault.clear()
                runOnUiThread { callback(SessionCheck.SignedOut) }
                return@execute
            }

            vault.saveSession(refreshed)
            val second = api.readMe(refreshed.accessToken)
            val user = second.user
            if (user != null) {
                runOnUiThread { callback(SessionCheck.SignedIn(user)) }
            } else {
                vault.clear()
                runOnUiThread { callback(SessionCheck.SignedOut) }
            }
        }
    }

    private fun signIn(email: String, password: String, callback: (Result<CloudUser>) -> Unit) {
        worker.execute {
            val result = runCatching {
                val auth = api.signIn(email.trim(), password)
                vault.saveSession(auth.session)
                auth.user
            }
            runOnUiThread { callback(result) }
        }
    }

    private fun register(
        name: String,
        email: String,
        password: String,
        callback: (Result<CloudUser>) -> Unit
    ) {
        worker.execute {
            val result = runCatching {
                val auth = api.register(name.trim(), email.trim(), password)
                vault.saveSession(auth.session)
                auth.user
            }
            runOnUiThread { callback(result) }
        }
    }

    private fun requestPasswordReset(
        email: String,
        callback: (Result<PasswordResetRequestResult>) -> Unit
    ) {
        worker.execute {
            val result = runCatching { api.requestPasswordReset(email.trim()) }
            runOnUiThread { callback(result) }
        }
    }

    private fun confirmPasswordReset(
        token: String,
        newPassword: String,
        callback: (Result<String>) -> Unit
    ) {
        worker.execute {
            val result = runCatching { api.confirmPasswordReset(token.trim(), newPassword) }
            runOnUiThread { callback(result) }
        }
    }

    private fun signOut() {
        vault.clear()
    }

    private fun openCloudHome() {
        startActivity(
            Intent(this, CloudHomeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        )
        finish()
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }
}

@Composable
private fun CloudAccountScreen(
    initialMessage: String,
    checkExistingSession: ((SessionCheck) -> Unit) -> Unit,
    signIn: (String, String, (Result<CloudUser>) -> Unit) -> Unit,
    register: (String, String, String, (Result<CloudUser>) -> Unit) -> Unit,
    requestPasswordReset: (String, (Result<PasswordResetRequestResult>) -> Unit) -> Unit,
    confirmPasswordReset: (String, String, (Result<String>) -> Unit) -> Unit,
    signOut: () -> Unit,
    openCloudHome: () -> Unit
) {
    var mode by remember { mutableStateOf(AccountMode.SIGN_IN) }
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var resetToken by remember { mutableStateOf("") }
    var newPassword by remember { mutableStateOf("") }
    var confirmPassword by remember { mutableStateOf("") }
    var resetCodeRequested by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(true) }
    var message by remember {
        mutableStateOf(initialMessage.ifBlank { "Getting things ready…" })
    }
    var messageIsError by remember { mutableStateOf(false) }
    var signedInUser by remember { mutableStateOf<CloudUser?>(null) }

    LaunchedEffect(Unit) {
        checkExistingSession { result ->
            when (result) {
                is SessionCheck.SignedIn -> {
                    signedInUser = result.user
                    message = "Opening My Lamps…"
                    messageIsError = false
                    openCloudHome()
                }
                SessionCheck.SignedOut -> {
                    if (initialMessage.isBlank()) message = "Sign in to continue."
                    messageIsError = false
                }
                is SessionCheck.Failed -> {
                    message = result.message
                    messageIsError = true
                }
            }
            busy = false
        }
    }

    Scaffold(containerColor = AccountBackground) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            BrandHeader()
            Spacer(Modifier.height(24.dp))

            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(26.dp),
                colors = CardDefaults.cardColors(
                    containerColor = AccountSurface,
                    contentColor = AccountText
                ),
                elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
            ) {
                Column(modifier = Modifier.padding(20.dp)) {
                    val user = signedInUser
                    when {
                        user != null -> SignedInContent(
                            user = user,
                            openHome = openCloudHome,
                            signOut = {
                                signOut()
                                signedInUser = null
                                password = ""
                                message = "You have been signed out."
                                messageIsError = false
                            }
                        )

                        mode == AccountMode.RESET_PASSWORD -> ResetPasswordContent(
                            email = email,
                            onEmailChange = { email = it },
                            resetToken = resetToken,
                            onResetTokenChange = { resetToken = it },
                            newPassword = newPassword,
                            onNewPasswordChange = { newPassword = it },
                            confirmPassword = confirmPassword,
                            onConfirmPasswordChange = { confirmPassword = it },
                            resetCodeRequested = resetCodeRequested,
                            busy = busy,
                            requestCode = {
                                val cleanEmail = email.trim()
                                if (cleanEmail.isBlank()) {
                                    message = "Enter your email address."
                                    messageIsError = true
                                } else {
                                    busy = true
                                    message = "Sending your reset code…"
                                    messageIsError = false
                                    requestPasswordReset(cleanEmail) { result ->
                                        busy = false
                                        result.onSuccess { response ->
                                            resetCodeRequested = true
                                            response.debugResetToken?.let { resetToken = it }
                                            message = if (response.debugResetToken != null) {
                                                "Reset code ready. Choose a new password."
                                            } else {
                                                "Check your email for the reset code."
                                            }
                                            messageIsError = false
                                        }.onFailure { error ->
                                            message = friendlyAccountError(error)
                                            messageIsError = true
                                        }
                                    }
                                }
                            },
                            resetPassword = {
                                when {
                                    resetToken.trim().length < 32 -> {
                                        message = "Enter the complete reset code."
                                        messageIsError = true
                                    }
                                    newPassword.length < 8 -> {
                                        message = "Use at least 8 characters for your new password."
                                        messageIsError = true
                                    }
                                    newPassword != confirmPassword -> {
                                        message = "The two passwords do not match."
                                        messageIsError = true
                                    }
                                    else -> {
                                        busy = true
                                        message = "Updating your password…"
                                        messageIsError = false
                                        confirmPasswordReset(resetToken, newPassword) { result ->
                                            busy = false
                                            result.onSuccess {
                                                mode = AccountMode.SIGN_IN
                                                password = ""
                                                resetToken = ""
                                                newPassword = ""
                                                confirmPassword = ""
                                                resetCodeRequested = false
                                                message = "Password updated. Sign in with your new password."
                                                messageIsError = false
                                            }.onFailure { error ->
                                                message = friendlyAccountError(error)
                                                messageIsError = true
                                            }
                                        }
                                    }
                                }
                            },
                            backToSignIn = {
                                mode = AccountMode.SIGN_IN
                                resetToken = ""
                                newPassword = ""
                                confirmPassword = ""
                                resetCodeRequested = false
                                message = "Sign in to continue."
                                messageIsError = false
                            }
                        )

                        else -> SignInCreateContent(
                            mode = mode,
                            onModeChange = {
                                mode = it
                                message = if (it == AccountMode.SIGN_IN) {
                                    "Sign in to continue."
                                } else {
                                    "Create your SH Lamp account."
                                }
                                messageIsError = false
                            },
                            name = name,
                            onNameChange = { name = it },
                            email = email,
                            onEmailChange = { email = it },
                            password = password,
                            onPasswordChange = { password = it },
                            busy = busy,
                            submit = {
                                val cleanEmail = email.trim()
                                when {
                                    cleanEmail.isBlank() -> {
                                        message = "Enter your email address."
                                        messageIsError = true
                                    }
                                    mode == AccountMode.SIGN_IN && password.isBlank() -> {
                                        message = "Enter your password."
                                        messageIsError = true
                                    }
                                    mode == AccountMode.CREATE_ACCOUNT && password.length < 8 -> {
                                        message = "Use at least 8 characters for your password."
                                        messageIsError = true
                                    }
                                    mode == AccountMode.CREATE_ACCOUNT && name.trim().length < 2 -> {
                                        message = "Enter your name."
                                        messageIsError = true
                                    }
                                    else -> {
                                        busy = true
                                        message = if (mode == AccountMode.SIGN_IN) {
                                            "Signing you in…"
                                        } else {
                                            "Creating your account…"
                                        }
                                        messageIsError = false

                                        val callback: (Result<CloudUser>) -> Unit = { result ->
                                            busy = false
                                            result.onSuccess {
                                                signedInUser = it
                                                password = ""
                                                message = "Opening My Lamps…"
                                                messageIsError = false
                                                openCloudHome()
                                            }.onFailure { error ->
                                                message = friendlyAccountError(error)
                                                messageIsError = true
                                            }
                                        }

                                        if (mode == AccountMode.SIGN_IN) {
                                            signIn(cleanEmail, password, callback)
                                        } else {
                                            register(name, cleanEmail, password, callback)
                                        }
                                    }
                                }
                            },
                            forgotPassword = {
                                mode = AccountMode.RESET_PASSWORD
                                password = ""
                                message = "Enter your email to reset your password."
                                messageIsError = false
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            MessageBanner(message = message, isError = messageIsError, busy = busy)
            Spacer(Modifier.height(16.dp))
            Text(
                "Secure access to your SH Lamp home",
                color = AccountTextSecondary,
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}

@Composable
private fun BrandHeader() {
    Box(
        modifier = Modifier
            .size(64.dp)
            .background(AccountAccent, CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Text("SH", color = AccountOnAccent, fontSize = 22.sp, fontWeight = FontWeight.Bold)
    }
    Spacer(Modifier.height(14.dp))
    Text("SH Lamp", color = AccountText, fontSize = 32.sp, fontWeight = FontWeight.Bold)
    Spacer(Modifier.height(5.dp))
    Text(
        "Your smart lighting, one tap away",
        color = AccountTextSecondary,
        style = MaterialTheme.typography.bodyMedium
    )
}

@Composable
private fun SignedInContent(
    user: CloudUser,
    openHome: () -> Unit,
    signOut: () -> Unit
) {
    Text(
        "Welcome back${user.name.trim().takeIf { it.isNotBlank() }?.let { ", ${it.substringBefore(' ')}" } ?: ""}",
        color = AccountText,
        fontSize = 23.sp,
        fontWeight = FontWeight.Bold
    )
    Spacer(Modifier.height(6.dp))
    Text(user.email, color = AccountTextSecondary, style = MaterialTheme.typography.bodyMedium)
    Spacer(Modifier.height(20.dp))

    PrimaryButton(text = "Open My Lamps", onClick = openHome)
    Spacer(Modifier.height(6.dp))
    TextButton(
        onClick = signOut,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.textButtonColors(contentColor = AccountTextSecondary)
    ) {
        Text("Sign out")
    }
}

@Composable
private fun SignInCreateContent(
    mode: AccountMode,
    onModeChange: (AccountMode) -> Unit,
    name: String,
    onNameChange: (String) -> Unit,
    email: String,
    onEmailChange: (String) -> Unit,
    password: String,
    onPasswordChange: (String) -> Unit,
    busy: Boolean,
    submit: () -> Unit,
    forgotPassword: () -> Unit
) {
    AccountModeSelector(mode = mode, onModeChange = onModeChange)
    Spacer(Modifier.height(20.dp))

    Text(
        if (mode == AccountMode.SIGN_IN) "Welcome back" else "Create your account",
        color = AccountText,
        fontSize = 22.sp,
        fontWeight = FontWeight.Bold
    )
    Spacer(Modifier.height(6.dp))
    Text(
        if (mode == AccountMode.SIGN_IN) {
            "Sign in to manage your lamps."
        } else {
            "Set up your account in a few seconds."
        },
        color = AccountTextSecondary,
        style = MaterialTheme.typography.bodyMedium
    )
    Spacer(Modifier.height(18.dp))

    if (mode == AccountMode.CREATE_ACCOUNT) {
        FriendlyTextField(
            value = name,
            onValueChange = onNameChange,
            label = "Name",
            enabled = !busy
        )
        Spacer(Modifier.height(11.dp))
    }

    FriendlyTextField(
        value = email,
        onValueChange = onEmailChange,
        label = "Email",
        enabled = !busy
    )
    Spacer(Modifier.height(11.dp))
    FriendlyTextField(
        value = password,
        onValueChange = onPasswordChange,
        label = "Password",
        enabled = !busy,
        password = true
    )
    Spacer(Modifier.height(18.dp))

    PrimaryButton(
        text = if (mode == AccountMode.SIGN_IN) "Sign in" else "Create account",
        onClick = submit,
        enabled = !busy,
        busy = busy
    )

    if (mode == AccountMode.SIGN_IN) {
        TextButton(
            onClick = forgotPassword,
            enabled = !busy,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.textButtonColors(contentColor = AccountAccent)
        ) {
            Text("Forgot password?")
        }
    }

}

@Composable
private fun AccountModeSelector(
    mode: AccountMode,
    onModeChange: (AccountMode) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        ModeButton(
            text = "Sign in",
            selected = mode == AccountMode.SIGN_IN,
            onClick = { onModeChange(AccountMode.SIGN_IN) },
            modifier = Modifier.weight(1f)
        )
        ModeButton(
            text = "Create account",
            selected = mode == AccountMode.CREATE_ACCOUNT,
            onClick = { onModeChange(AccountMode.CREATE_ACCOUNT) },
            modifier = Modifier.weight(1f)
        )
    }
}

@Composable
private fun ModeButton(
    text: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    if (selected) {
        Button(
            onClick = onClick,
            modifier = modifier,
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = AccountAccentSoft,
                contentColor = AccountAccent
            )
        ) {
            Text(text, fontWeight = FontWeight.Bold)
        }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = modifier,
            shape = RoundedCornerShape(14.dp),
            border = BorderStroke(1.dp, AccountBorder),
            colors = ButtonDefaults.outlinedButtonColors(contentColor = AccountText)
        ) {
            Text(text, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun ResetPasswordContent(
    email: String,
    onEmailChange: (String) -> Unit,
    resetToken: String,
    onResetTokenChange: (String) -> Unit,
    newPassword: String,
    onNewPasswordChange: (String) -> Unit,
    confirmPassword: String,
    onConfirmPasswordChange: (String) -> Unit,
    resetCodeRequested: Boolean,
    busy: Boolean,
    requestCode: () -> Unit,
    resetPassword: () -> Unit,
    backToSignIn: () -> Unit
) {
    Text("Reset your password", color = AccountText, fontSize = 22.sp, fontWeight = FontWeight.Bold)
    Spacer(Modifier.height(6.dp))
    Text(
        "We'll send a one-time code to your account email.",
        color = AccountTextSecondary,
        style = MaterialTheme.typography.bodyMedium
    )
    Spacer(Modifier.height(18.dp))

    FriendlyTextField(
        value = email,
        onValueChange = onEmailChange,
        label = "Email",
        enabled = !busy
    )
    Spacer(Modifier.height(12.dp))
    PrimaryButton(
        text = if (resetCodeRequested) "Send another code" else "Send reset code",
        onClick = requestCode,
        enabled = !busy,
        busy = busy && !resetCodeRequested
    )

    if (resetCodeRequested) {
        Spacer(Modifier.height(18.dp))
        FriendlyTextField(
            value = resetToken,
            onValueChange = onResetTokenChange,
            label = "Reset code",
            enabled = !busy
        )
        Spacer(Modifier.height(11.dp))
        FriendlyTextField(
            value = newPassword,
            onValueChange = onNewPasswordChange,
            label = "New password",
            enabled = !busy,
            password = true
        )
        Spacer(Modifier.height(11.dp))
        FriendlyTextField(
            value = confirmPassword,
            onValueChange = onConfirmPasswordChange,
            label = "Confirm new password",
            enabled = !busy,
            password = true
        )
        Spacer(Modifier.height(16.dp))
        PrimaryButton(
            text = "Update password",
            onClick = resetPassword,
            enabled = !busy,
            busy = busy
        )
    }

    Spacer(Modifier.height(6.dp))
    TextButton(
        onClick = backToSignIn,
        enabled = !busy,
        modifier = Modifier.fillMaxWidth(),
        colors = ButtonDefaults.textButtonColors(contentColor = AccountAccent)
    ) {
        Text("Back to sign in")
    }
}

@Composable
private fun FriendlyTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    enabled: Boolean,
    password: Boolean = false
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(15.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = AccountText,
            unfocusedTextColor = AccountText,
            disabledTextColor = AccountTextSecondary,
            cursorColor = AccountAccent,
            focusedBorderColor = AccountAccent,
            unfocusedBorderColor = AccountBorder,
            disabledBorderColor = AccountBorder,
            focusedLabelColor = AccountAccent,
            unfocusedLabelColor = AccountTextSecondary,
            disabledLabelColor = AccountTextSecondary,
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent
        )
    )
}

@Composable
private fun PrimaryButton(
    text: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    busy: Boolean = false
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
        shape = RoundedCornerShape(16.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = AccountAccent,
            contentColor = AccountOnAccent,
            disabledContainerColor = AccountAccentSoft,
            disabledContentColor = AccountTextSecondary
        )
    ) {
        if (busy) {
            CircularProgressIndicator(
                modifier = Modifier.size(21.dp),
                strokeWidth = 2.dp,
                color = AccountOnAccent
            )
        } else {
            Text(text, fontWeight = FontWeight.Bold, fontSize = 16.sp)
        }
    }
}

@Composable
private fun SecondaryButton(
    text: String,
    onClick: () -> Unit,
    enabled: Boolean = true
) {
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .height(50.dp),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, AccountBorder),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = AccountText,
            disabledContentColor = AccountTextSecondary
        )
    ) {
        Text(text, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun MessageBanner(message: String, isError: Boolean, busy: Boolean) {
    if (message.isBlank()) return
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(15.dp),
        colors = CardDefaults.cardColors(
            containerColor = if (isError) AccountErrorSoft else AccountSuccessSoft,
            contentColor = if (isError) AccountError else AccountSuccess
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (busy) {
                CircularProgressIndicator(
                    modifier = Modifier.size(17.dp),
                    strokeWidth = 2.dp,
                    color = AccountAccent
                )
                Spacer(Modifier.size(9.dp))
            }
            Text(
                message,
                color = if (isError) AccountError else AccountText,
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

private fun friendlyAccountError(error: Throwable): String {
    val text = error.message.orEmpty().lowercase()
    return when {
        "email or password" in text || "invalid_credentials" in text ->
            "Email or password is incorrect."
        "email_in_use" in text || "already exists" in text ->
            "An account already exists for this email."
        "reset" in text && ("expired" in text || "invalid" in text || "used" in text) ->
            "That reset code is no longer valid. Request a new one."
        "timeout" in text || "unable to resolve" in text || "failed to connect" in text ||
            "network" in text || "connection" in text ->
            "Check your internet connection and try again."
        else -> "Something went wrong. Please try again."
    }
}
