package com.example.shlamp

/**
 * Phase 1 local controller registry.
 *
 * This records approved controller names inside the lamp for identification
 * and revocation UI. It is not yet cryptographic authentication; signed
 * invitations and secure tokens belong to the security phase.
 */
internal class LampAccessManager(
    private val repository: LampRepository,
    private val bleManager: BleLampManager
) {
    val thisControllerId: String
        get() = repository.controllerId

    val thisControllerLabel: String
        get() = repository.controllerLabel

    fun registerThisPhone() {
        bleManager.registerController(thisControllerId, thisControllerLabel)
    }

    fun refresh() {
        bleManager.requestControllers()
    }

    fun remove(controllerId: String) {
        bleManager.removeController(controllerId)
    }

    fun renameThisPhone(label: String) {
        repository.controllerLabel = label
        registerThisPhone()
    }
}
