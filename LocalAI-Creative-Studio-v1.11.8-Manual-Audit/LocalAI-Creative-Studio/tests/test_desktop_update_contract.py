from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WindowsSourceSafetyContracts(unittest.TestCase):
    """Source guards for Windows scripts; these do not emulate PowerShell or Windows."""

    @classmethod
    def setUpClass(cls):
        cls.updater = (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8-sig")
        cls.installer = (ROOT / "scripts" / "INSTALL-DESKTOP-APP.ps1").read_text(encoding="utf-8-sig")
        cls.launcher = (ROOT / "scripts" / "LAUNCH-DESKTOP.ps1").read_text(encoding="utf-8-sig")
        cls.stopper = (ROOT / "scripts" / "STOP-STUDIO.ps1").read_text(encoding="utf-8-sig")
        cls.checker = (ROOT / "scripts" / "CHECK-STUDIO.ps1").read_text(encoding="utf-8-sig")
        cls.data_path = (ROOT / "scripts" / "DATA-PATH.ps1").read_text(encoding="utf-8-sig")

    def test_update_stages_and_verifies_backups_before_stopping_studio(self):
        stage = self.updater.index("# Stage and hash-check")
        backup = self.updater.index("# Back up every package-owned file")
        stop = self.updater.index("Stopping only the LocalAI Creative Studio service")
        replace = self.updater.index("Copy-Item -LiteralPath $sourceFile -Destination $targetFile")
        self.assertLess(stage, backup)
        self.assertLess(backup, stop)
        self.assertLess(stop, replace)
        self.assertIn("$backupHash -ne $actual", self.updater)

    def test_updater_tracks_manifest_itself_through_backup_install_and_rollback(self):
        self.assertIn("$NewManifest['MANIFEST-SHA256.txt']", self.updater)
        self.assertIn("$oldManifest['MANIFEST-SHA256.txt']", self.updater)
        self.assertIn("Test-ManifestFiles $StageRoot $NewManifest", self.updater)
        self.assertIn("Test-ManifestFiles $InstallRoot $NewManifest", self.updater)
        self.assertIn("Restore-Update $BackupRoot $BackupMap", self.updater)

    def test_first_install_verifies_the_copied_package_manifest(self):
        child_args = self.installer.split("$installedArgs = ", 1)[1].splitlines()[0]
        self.assertIn("-Installed", child_args)
        self.assertNotIn("-SkipPackageVerification", child_args)

    def test_rollback_does_not_rerun_the_restored_legacy_installer(self):
        self.assertNotIn("$oldInstaller = Join-Path $InstallRoot", self.updater)
        self.assertIn("The previous installer was not rerun", self.updater)
        self.assertIn("Restore-Update $BackupRoot $BackupMap", self.updater)

    def test_rollback_checks_backup_and_restored_file_hashes(self):
        self.assertIn("$backupHash -ne $expectedBackupHash", self.updater)
        self.assertIn("$restoredHash -ne $expectedBackupHash", self.updater)
        self.assertIn("Restore-Update $BackupRoot $BackupMap", self.updater)

    def test_update_never_uses_destructive_robocopy_mirror(self):
        for source in (self.updater, self.installer):
            self.assertNotIn("/MIR", source.upper())
            self.assertIn("'/E'", source)
            self.assertIn("'/XJ'", source)

    def test_update_preserves_database_logs_media_and_virtual_environment(self):
        for token in ("'.venv'", "'.venv.next'", "'*.sqlite*'", "'*.db*'", "'*.log'", "'*.tmp'"):
            self.assertIn(token, self.updater)
        for token in ("'*.sqlite*'", "'*.db*'", "'*.log'", "'*.tmp'"):
            self.assertIn(token, self.installer)

    def test_stop_script_targets_only_private_studio_python_and_uvicorn_port(self):
        self.assertIn("Win32_Process", self.stopper)
        self.assertIn("$PythonExpected", self.stopper)
        self.assertIn("uvicorn\\s+studio\\.server:app", self.stopper)
        self.assertIn("--port\\s+7865", self.stopper)
        self.assertIn("Stop-Process -Id $process.ProcessId", self.stopper)
        self.assertNotRegex(self.stopper, re.compile(r"(?i)Stop-Process\s+.*-Name"))

    def test_launcher_binds_only_to_loopback_and_rejects_foreign_port_owner(self):
        self.assertIn("127.0.0.1", self.launcher)
        self.assertIn("--port 7865", self.launcher)
        self.assertIn("not this LocalAI Studio service", self.launcher)
        self.assertIn("param([switch]$NoBrowser)", self.launcher)

    def test_data_path_is_limited_to_the_two_supported_user_locations(self):
        self.assertIn("CreativeStudioDataRoot.txt", self.data_path)
        self.assertIn("$driveHome = 'D:\\LocalAI'", self.data_path)
        self.assertIn("$driveData = Join-Path $driveHome 'CreativeStudioData'", self.data_path)
        self.assertIn("CreativeStudioData", self.data_path)
        self.assertIn("Refusing to use a redirected Studio data folder", self.data_path)
        self.assertIn("outside the two supported data locations", self.data_path)

    def test_diagnostics_uses_health_endpoint_for_engine_state(self):
        self.assertIn("/api/health", self.checker)
        self.assertNotIn("/api/ready", self.checker)

    def test_installer_checks_official_python_hash_and_authenticode_before_execution(self):
        hash_check = self.installer.index("$actualSha256 -ne $expectedSha256")
        signature_check = self.installer.index("Get-AuthenticodeSignature -LiteralPath $installerPath")
        execute = self.installer.index("Start-Process -FilePath $installerPath")
        self.assertLess(hash_check, execute)
        self.assertLess(signature_check, execute)
        self.assertIn("Python Software Foundation", self.installer)
        self.assertIn("PrependPath=0", self.installer)
        self.assertIn("AppendPath=0", self.installer)


    def test_python_runtime_probes_ignore_user_python_path_overrides(self):
        self.assertIn("'PYTHONHOME', 'PYTHONPATH'", self.installer)
        self.assertIn("$commandArguments = @('-I') + @($Arguments)", self.installer)
        self.assertIn("function Invoke-PythonProbe", self.installer)
        self.assertIn("function Invoke-PythonCommand", self.installer)
        self.assertIn("$psi.EnvironmentVariables.Remove($name)", self.installer)
        self.assertNotIn("Remove-Item -LiteralPath $environmentPath", self.installer)


    def test_python_process_runner_captures_stderr_without_powershell_native_error_promotion(self):
        self.assertIn("function ConvertTo-WindowsCommandLineArgument", self.installer)
        self.assertIn("function Join-WindowsProcessArguments", self.installer)
        self.assertIn("function Invoke-LocalAIChildProcess", self.installer)
        self.assertIn("System.Diagnostics.ProcessStartInfo", self.installer)
        self.assertIn("RedirectStandardOutput = $redirect", self.installer)
        self.assertIn("RedirectStandardError = $redirect", self.installer)
        self.assertIn("ReadToEndAsync()", self.installer)
        self.assertIn("$process.WaitForExit($TimeoutSec * 1000)", self.installer)
        self.assertIn("$process.Kill()", self.installer)
        self.assertNotIn("@(& $Executable", self.installer)
        self.assertNotIn("& $launcher.Source", self.installer)

    def test_python_launcher_discovery_uses_same_safe_process_runner(self):
        discovery = self.installer.split('function Find-UsablePython', 1)[1].split('function Install-OfficialPython', 1)[0]
        self.assertIn("Invoke-LocalAIChildProcess -FilePath $launcher.Source", discovery)
        self.assertNotIn("$LASTEXITCODE", discovery)

    def test_python_bootstrap_failure_preserves_actual_probe_diagnostics(self):
        self.assertIn("Format-PythonProbeFailure", self.installer)
        self.assertIn("$script:LastPythonProbe", self.installer)
        self.assertIn("$failedProbe = $script:LastPythonProbe", self.installer)
        self.assertIn("python.exe", self.installer)
        self.assertIn("instead of running the same installer", self.installer)

    def test_only_app_owned_python_runtime_may_bootstrap_missing_pip(self):
        discovery = self.installer.split('function Find-UsablePython', 1)[1].split('function Install-OfficialPython', 1)[0]
        self.assertNotIn("ensurepip', '--upgrade", discovery)
        private_install = self.installer.split('function Install-OfficialPython', 1)[1]
        self.assertIn("@('-m', 'ensurepip', '--upgrade')", private_install)

    def test_python_application_commands_use_clean_environment_runner(self):
        self.assertIn("Invoke-PythonCommand -Executable $basePython", self.installer)
        self.assertIn("Invoke-PythonCommand -Executable $CandidatePython", self.installer)
        self.assertIn("Invoke-PythonCommand -Executable $PythonExe", self.installer)
        self.assertIn("$script:LastPythonExitCode", self.installer)

    def test_installer_promotes_virtual_environment_only_after_application_checks(self):
        suite = self.installer.index("@('-m', 'unittest', 'discover'")
        promote = self.installer.index("Move-Item -LiteralPath $CandidateVenv -Destination $Venv")
        shortcuts = self.installer.index("Step 'Prepare desktop launcher and shortcuts'")
        self.assertLess(suite, promote)
        self.assertLess(suite, shortcuts)

    def test_installer_passes_the_matching_vbs_path_to_each_shortcut(self):
        launch_path = "Write-SafeShortcut $shortcutPath $WScript"
        exit_path = "Write-SafeShortcut $stopShortcutPath $WScript"
        self.assertIn("'Open LocalAI Creative Studio as a desktop app window' \"$Icon,0\" $shell $WScript $VbsPath", self.installer)
        self.assertIn("'Exit LocalAI Creative Studio only' \"$Icon,0\" $shell $WScript $stopVbs", self.installer)
        self.assertLess(self.installer.index("$VbsPath = Join-Path $Root"), self.installer.index(launch_path))
        self.assertLess(self.installer.index("$stopVbs = Join-Path $Root"), self.installer.index(exit_path))

    def test_launcher_vbs_points_to_the_local_powershell_script(self):
        for name, target in (
            ("Launch-LocalAI-Creative-Studio.vbs", "scripts\\LAUNCH-DESKTOP.ps1"),
            ("Exit-LocalAI-Creative-Studio.vbs", "scripts\\STOP-STUDIO.ps1"),
        ):
            source = (ROOT / name).read_text(encoding="utf-8")
            with self.subTest(file=name):
                self.assertIn(target, source)
                self.assertIn("WScript.ScriptFullName", source)
