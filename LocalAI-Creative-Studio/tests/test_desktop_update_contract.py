from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DesktopUpdateContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.update_bat = (ROOT / "APPLY-UPDATE.bat").read_text(encoding="utf-8")
        cls.setup_bat = (ROOT / "SETUP-AND-START.bat").read_text(encoding="utf-8")
        cls.updater = (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8")
        cls.installer = (ROOT / "scripts" / "INSTALL-DESKTOP-APP.ps1").read_text(encoding="utf-8-sig")
        cls.launcher = (ROOT / "scripts" / "LAUNCH-DESKTOP.ps1").read_text(encoding="utf-8")
        cls.verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8")
        cls.data_path = (ROOT / "scripts" / "DATA-PATH.ps1").read_text(encoding="utf-8-sig")

    def test_dedicated_update_file_calls_update_script(self):
        self.assertIn("scripts\\APPLY-UPDATE.ps1", self.update_bat)
        self.assertIn("UPDATE COMPLETE", self.update_bat)

    def test_setup_file_is_both_first_install_and_future_update_entrypoint(self):
        self.assertIn("scripts\\INSTALL-DESKTOP-APP.ps1", self.setup_bat)
        self.assertIn("APPLY-UPDATE.ps1", self.installer)

    def test_update_verifies_package_before_staging(self):
        verify_at = self.updater.index("VERIFY-PACKAGE.ps1")
        stage_at = self.updater.index("# Stage and hash-check")
        self.assertLess(verify_at, stage_at)
        self.assertIn("if ($LASTEXITCODE -ne 0)", self.updater[verify_at:stage_at])

    def test_update_uses_non_mirroring_copy(self):
        self.assertIn("'/E'", self.updater)
        self.assertNotIn("'/MIR'", self.updater)
        self.assertIn("'/E'", self.installer)
        self.assertNotIn("'/MIR'", self.installer)

    def test_update_stages_before_stop_but_only_replaces_after_stop(self):
        stage_at = self.updater.index("# Stage and hash-check")
        stop_at = self.updater.index("STOP-STUDIO.ps1")
        live_copy_at = self.updater.index("Copy-Item -LiteralPath $sourceFile -Destination $targetFile")
        self.assertLess(stage_at, stop_at)
        self.assertLess(stop_at, live_copy_at)
        self.assertIn("if ($LASTEXITCODE -ne 0)", self.updater[stop_at:live_copy_at])

    def test_venv_and_user_database_files_are_excluded_from_update_staging(self):
        for token in ("'.venv'", "'.venv.next'", "'*.sqlite*'", "'*.db*'", "'*.log'", "'*.tmp'"):
            self.assertIn(token, self.updater)

    def test_user_database_and_logs_are_excluded_from_first_install_copy(self):
        self.assertIn("'*.sqlite*'", self.installer)
        self.assertIn("'*.db*'", self.installer)
        self.assertIn("'*.log'", self.installer)
        self.assertIn("'*.tmp'", self.installer)
        self.assertNotIn("'/MIR'", self.installer)

    def test_obsolete_package_files_are_deleted_only_if_hash_matches(self):
        self.assertIn("$currentHash -eq $oldManifest[$relative]", self.updater)
        self.assertIn("Kept locally modified obsolete file", self.updater)

    def test_manifest_paths_are_checked_for_traversal(self):
        self.assertIn("$segment -in @('.', '..')", self.updater)
        self.assertIn("$target.StartsWith($baseFull", self.updater)
        self.assertIn("PATH ESCAPES PACKAGE ROOT", self.verifier)

    def test_every_new_file_is_hash_verified_in_stage_and_installed_copy(self):
        self.assertIn("Test-ManifestFiles $StageRoot $NewManifest", self.updater)
        self.assertIn("$installedHash -ne $NewManifest[$relative]", self.updater)
        self.assertIn("Test-ManifestFiles $InstallRoot $NewManifest", self.updater)

    def test_update_has_rollback_for_new_and_replaced_files(self):
        self.assertIn("function Restore-Update", self.updater)
        self.assertIn("$BackupMap[$relative] = $true", self.updater)
        self.assertIn("Restore-Update $BackupRoot $BackupMap $CreatedFiles $NewManifest", self.updater)

    def test_icon_cache_path_changes_when_icon_binary_changes(self):
        self.assertIn("Get-FileHash -LiteralPath $IconSource", self.installer)
        self.assertIn("$IconHash + '.ico'", self.installer)
        self.assertIn("$cachedHash -ne $IconHash", self.installer)
        self.assertIn("Copy-Item -LiteralPath $IconSource -Destination $Icon -ErrorAction Stop", self.installer)
        self.assertIn("$shortcut.IconLocation = $IconLocation", self.installer)
        self.assertIn('"$Icon,0"', self.installer)

    def test_shortcut_is_recreated_against_installed_application_launcher(self):
        self.assertIn("$VbsPath = Join-Path $Root 'Launch-LocalAI-Creative-Studio.vbs'", self.installer)
        self.assertIn("function Write-SafeShortcut", self.installer)
        self.assertIn("Write-SafeShortcut $shortcutPath $WScript", self.installer)
        self.assertIn("('//B //Nologo \"' + $VbsPath", self.installer)
        self.assertIn("[System.IO.File]::Move($temporary, $ShortcutPath)", self.installer)
        self.assertIn("[System.IO.File]::Replace($temporary, $ShortcutPath, $backup)", self.installer)
        self.assertIn("$backup = Join-Path $directory", self.installer)
        self.assertNotIn("$backup = Join-Path $BackupDirectory", self.installer)
        self.assertIn("File.Replace requires all", self.installer)

    def test_user_data_path_is_persisted_and_shared_with_launcher(self):
        marker = "CreativeStudioDataRoot.txt"
        self.assertIn(marker, self.data_path)
        self.assertIn("Get-LocalAIDataRoot", self.installer)
        self.assertIn("Get-LocalAIDataRoot", self.launcher)
        self.assertIn("LOCALAI_STUDIO_DATA", self.launcher)

    def test_legacy_data_path_is_recovered_on_first_upgrade(self):
        self.assertIn("DESKTOP-APP-STATUS.txt", self.data_path)
        self.assertIn("^DATA:", self.data_path)
        self.assertIn("CreativeStudioDataRoot.txt", self.data_path)
        self.assertIn("DATA-PATH.ps1", self.updater)

    def test_dependencies_are_reused_only_when_hash_imports_and_pip_check_are_healthy(self):
        self.assertIn("requirements.sha256", self.installer)
        self.assertIn("$priorRequirementsHash -eq $requirementsHash", self.installer)
        self.assertIn("Test-StudioEnvironment $Python", self.installer)
        self.assertIn("pip check", self.installer)
        self.assertIn("No package download is required", self.installer)

    def test_update_refreshes_shortcut_using_installed_setup(self):
        self.assertIn("INSTALL-DESKTOP-APP.ps1", self.updater)
        self.assertIn("-Installed", self.updater)
        self.assertIn("-SkipPackageVerification", self.updater)
        self.assertIn("APPLY-UPDATE.bat", (ROOT / "README-AR.md").read_text(encoding="utf-8"))

    def test_no_launch_flag_prevents_process_start(self):
        section = self.installer.split('Step "Launch the desktop application"', 1)[1]
        self.assertRegex(section, re.compile(r"if \(\$NoLaunch\).*?else\s*\{.*?Start-Process -FilePath \$WScript", re.S))


    def test_full_regression_suite_runs_before_virtual_environment_promotion(self):
        function = self.installer.split("function Test-StudioApplication", 1)[1].split("function Step", 1)[0]
        self.assertIn("-m unittest discover", function)
        self.assertIn("Join-Path $Root 'tests'", function)
        suite_at = self.installer.index("-m unittest discover")
        promote_at = self.installer.index("Move-Item -LiteralPath $CandidateVenv -Destination $Venv")
        shortcut_at = self.installer.index("Step 'Prepare desktop launcher and shortcuts'")
        self.assertLess(suite_at, promote_at)
        self.assertLess(suite_at, shortcut_at)

    def test_python_dependencies_use_bounded_compatible_ranges(self):
        requirements = (ROOT / "requirements.txt").read_text(encoding="utf-8")
        expected = {
            "fastapi": ("0.128.2", "<1.0"),
            "uvicorn": ("0.48.0", "<1.0"),
            "httpx": ("0.28.1", "<1.0"),
            "python-multipart": ("0.0.29", "<1.0"),
            "psutil": ("7.2.2", "<8.0"),
            "pydantic": ("2.13.5", "<3.0"),
        }
        lines = {line.split(">", 1)[0].split("<", 1)[0].split("=", 1)[0].strip().lower(): line for line in requirements.splitlines() if line and not line.startswith("#")}
        for package, (minimum, maximum) in expected.items():
            with self.subTest(package=package):
                self.assertIn(package, lines)
                self.assertIn(">=" + minimum, lines[package])
                self.assertIn(maximum, lines[package])

    def test_dependency_installation_refuses_untested_source_builds(self):
        self.assertIn("--only-binary=:all:", self.installer)
        self.assertIn("pip check", self.installer)

    def test_launcher_waits_for_its_own_starting_service_and_rejects_foreign_listener(self):
        self.assertIn("The LocalAI service is already starting", self.launcher)
        self.assertIn("Win32_Process", self.launcher)
        self.assertIn("$owner.CommandLine -match '(?i)uvicorn\\s+studio\\.server:app'", self.launcher)
        self.assertIn("not this LocalAI Studio service", self.launcher)
        self.assertIn("did not become ready within 60 seconds", self.launcher)

    def test_diagnostic_and_package_verifier_use_the_builtin_windows_powershell(self):
        for filename in ("CHECK-STUDIO.bat", "VERIFY-PACKAGE.bat"):
            content = (ROOT / filename).read_text(encoding="utf-8")
            with self.subTest(filename=filename):
                self.assertIn("%WINDIR%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", content)
                self.assertIn('"%PS%"', content)

    def test_update_error_dialog_uses_explicit_windows_enum_values(self):
        self.assertIn("[System.Windows.Forms.MessageBoxButtons]::OK", self.updater)
        self.assertIn("[System.Windows.Forms.MessageBoxIcon]::Error", self.updater)

    def test_version_is_consistent_everywhere(self):
        version = (ROOT / "VERSION.txt").read_text(encoding="utf-8").strip()
        server = (ROOT / "studio" / "server.py").read_text(encoding="utf-8")
        html = (ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8")
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        self.assertIn("APP_VERSION = load_app_version()", server)
        self.assertIn('version_path = PACKAGE_ROOT / "VERSION.txt"', server)
        self.assertGreaterEqual(html.count("v__APP_VERSION__"), 2)

    def test_missing_python_is_downloaded_from_official_pinned_release(self):
        self.assertIn("https://www.python.org/ftp/python/3.14.10/python-3.14.10-amd64.exe", self.installer)
        self.assertIn("92480239264744fe0386a1bd8275786fefa126e3129e56a68e22b52c73329965", self.installer)
        self.assertIn("Install-OfficialPython", self.installer)
        self.assertIn("Invoke-WebRequest", self.installer)

    def test_python_candidate_is_rejected_if_python_exe_is_a_reparse_point(self):
        function = self.installer.split("function Test-PythonRuntime", 1)[1].split("function Test-PythonBootstrapRuntime", 1)[0]
        self.assertIn("Get-Item -LiteralPath $Executable -Force", function)
        self.assertIn("[IO.FileAttributes]::ReparsePoint", function)

    def test_python_installer_is_signature_and_hash_checked_before_execution(self):
        signature_at = self.installer.index("Get-AuthenticodeSignature -LiteralPath $installerPath")
        run_at = self.installer.index("Start-Process -FilePath $installerPath")
        self.assertLess(signature_at, run_at)
        self.assertIn("$signature.Status -ne 'Valid'", self.installer)
        self.assertIn("Python Software Foundation", self.installer)
        self.assertIn("$actualSha256 -ne $expectedSha256", self.installer)

    def test_python_installs_per_user_without_global_launcher_or_path_changes(self):
        self.assertIn("InstallAllUsers=0", self.installer)
        self.assertNotIn("InstallLauncherAllUsers=1", self.installer)
        self.assertIn("Include_launcher=0", self.installer)
        self.assertIn("PrependPath=0", self.installer)
        self.assertIn("AppendPath=0", self.installer)
        self.assertNotIn("SetEnvironmentVariable('Path'", self.installer)

    def test_python_full_install_includes_critical_components_and_log(self):
        for token in ("Include_dev=1", "Include_exe=1", "Include_lib=1", "Include_pip=1", "TargetDir=", "/log"):
            self.assertIn(token, self.installer)
        self.assertIn("pythonInstallLog", self.installer)

    def test_python_discovery_checks_registry_and_common_install_locations(self):
        self.assertIn("HKCU:\\SOFTWARE\\Python\\PythonCore", self.installer)
        self.assertIn("Python313\\python.exe", self.installer)
        self.assertIn("Find-UsablePython", self.installer)

    def test_python_bootstrap_checks_pip_venv_ssl_and_sqlite(self):
        for module in ("pip", "venv", "ensurepip", "ssl", "sqlite3", "ctypes"):
            self.assertIn(module, self.installer)

    def test_python_runtime_requires_supported_64bit_version(self):
        self.assertIn("sys.version_info >= (3,11)", self.installer)
        self.assertIn("sys.version_info < (3,15)", self.installer)
        self.assertIn("struct.calcsize(\"P\") == 8", self.installer)

    def test_desktop_shortcut_collisions_create_a_new_name_instead_of_overwriting(self):
        self.assertIn("Never overwrite a same-named shortcut owned by another application or the user", self.installer)
        self.assertIn("$BaseName + ' (' + $suffix + ').lnk'", self.installer)
        self.assertIn("[System.IO.File]::Move($temporary, $ShortcutPath)", self.installer)
        self.assertIn("The shortcut name became occupied by another program or user", self.installer)

    def test_python_installer_uses_localappdata_private_target_before_legacy_data_fallback(self):
        self.assertIn("LocalAI\\CreativeStudioRuntime\\Python314-LocalAI", self.installer)
        self.assertIn("Python314-LocalAI", self.installer)
        self.assertIn("Name = 'localappdata-primary'", self.installer)
        self.assertIn("Name = 'localappdata-fallback'", self.installer)
        self.assertIn("Name = 'legacy-localappdata-primary'", self.installer)
        self.assertIn("Name = 'legacy-data-primary'", self.installer)
        self.assertIn("/passive InstallAllUsers=0 TargetDir=", self.installer)
        self.assertIn("The D:/data-root targets remain as compatibility fallbacks", self.installer)

    def test_failed_python_probe_is_reported_and_multiple_safe_targets_are_retried(self):
        self.assertIn("Test-PythonBootstrapRuntime $directPython", self.installer)
        self.assertIn("$process.ExitCode", self.installer)
        self.assertIn("localappdata-primary", self.installer)
        self.assertIn("legacy-data-fallback", self.installer)
        self.assertIn("Last installer log", self.installer)

    def test_manifest_rejects_windows_reserved_and_ambiguous_path_segments(self):
        for text in (self.updater, self.verifier):
            self.assertIn("CON|PRN|AUX|NUL|CONIN", text)
            self.assertIn("COM[1-9]|LPT[1-9]", text)
            self.assertIn("EndsWith('.')", text)
            self.assertIn("EndsWith(' ')", text)
        self.assertIn("$segment -in @('.', '..')", self.updater)

    def test_setup_requires_64bit_windows_before_python_bootstrap(self):
        guard_at = self.installer.index("[Environment]::Is64BitOperatingSystem")
        python_at = self.installer.index("$basePython = Find-UsablePython")
        self.assertLess(guard_at, python_at)

    def test_setup_repairs_missing_dependencies_even_when_hash_unchanged(self):
        self.assertIn("$dependenciesReady = ($priorRequirementsHash -eq $requirementsHash) -and (Test-StudioEnvironment $Python)", self.installer)
        self.assertIn("if (-not $dependenciesReady)", self.installer)
        self.assertIn("pip check", self.installer)

    def test_application_smoke_test_runs_before_shortcut_creation(self):
        smoke_at = self.installer.index("Studio FastAPI app smoke test passed")
        shortcut_at = self.installer.index("Step 'Prepare desktop launcher and shortcuts'")
        self.assertLess(smoke_at, shortcut_at)
        self.assertIn("Push-Location $Root", self.installer)

    def test_installer_and_updater_exclude_development_caches_from_installed_payloads(self):
        self.assertIn("'.venv.next'", self.installer)
        self.assertIn("'.mypy_cache'", self.installer)
        self.assertIn("'.ruff_cache'", self.installer)
        self.assertIn("'node_modules'", self.installer)
        self.assertIn("'/XJ'", self.installer)
        updater = (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("'.mypy_cache'", updater)
        self.assertIn("'.ruff_cache'", updater)
        self.assertIn("'node_modules'", updater)
        self.assertIn("'/XJ'", updater)

    def test_app_runtime_is_promoted_transactionally(self):
        self.assertIn(".venv.next", self.installer)
        self.assertIn(".venv.previous-", self.installer)
        self.assertIn(".venv.failed-", self.installer)
        self.assertIn("Move-Item -LiteralPath $CandidateVenv -Destination $Venv", self.installer)

    def test_manifest_rebuild_uses_a_prepared_private_python_from_source_or_installed_root(self):
        rebuild = (ROOT / "REBUILD-MANIFEST.bat").read_text(encoding="utf-8")
        self.assertIn(".venv\\Scripts\\python.exe", rebuild)
        self.assertIn("GET-VERIFIED-INSTALL-ROOT.ps1", rebuild)
        self.assertIn('-File "%RESOLVER%"', rebuild)
        self.assertIn('"%PYTHON%" "%~dp0scripts\\build_manifest.py"', rebuild)
        self.assertNotIn("py -3", rebuild)
        self.assertNotIn("python scripts\\build_manifest.py", rebuild)

    def test_project_does_not_depend_on_winget_for_python_bootstrap(self):
        self.assertNotIn("winget install", self.installer.lower())
        self.assertIn("python.org", self.installer)

    def test_runtime_version_is_not_mistaken_for_a_generation_engine(self):
        readme = (ROOT / "README-AR.md").read_text(encoding="utf-8")
        self.assertIn("ComfyUI", readme)
        self.assertIn("لا تحتوي على أوزان", readme)

    def test_installer_never_deletes_or_overwrites_other_desktop_shortcuts(self):
        self.assertIn("Get-SafeShortcutPath", self.installer)
        self.assertIn("Never overwrite a same-named shortcut owned by another application", self.installer)
        self.assertIn("for ($suffix = 2; $suffix -le 99; $suffix++)", self.installer)
        self.assertIn("Test-OwnedShortcut", self.installer)
        self.assertNotRegex(self.installer, re.compile(r"Remove-Item[^\r\n]*(Desktop|StartMenu|\$Desktop|\$StartMenu)", re.I))
        self.assertNotIn("/MIR", self.installer.upper())

    def test_unverified_default_install_folder_is_preserved_and_safe_alternate_is_selected(self):
        self.assertIn("Get-AvailableLocalAIInstallRoot -DefaultRoot $DefaultInstallRoot", self.installer)
        self.assertIn("No existing item was changed", self.installer)
        resolver = (ROOT / "scripts" / "INSTALL-ROOT.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("LocalAI Creative Studio (Managed)", resolver)
        self.assertIn("Test-LocalAIInstallOwnerMarker", self.installer)
        self.assertIn("Test-LocalAILegacyInstall", self.installer)

    def test_preexisting_empty_install_root_is_reused_without_recreating_it(self):
        first_install = self.installer.split("# First install: only write into a new or explicitly owned folder.", 1)[1].split("$copyArgs =", 1)[0]
        self.assertIn("if (Test-Path -LiteralPath $InstallRoot -PathType Container)", first_install)
        self.assertIn("if (-not (Test-ManagedInstall))", first_install)
        self.assertIn("New-Item -ItemType Directory -Path $InstallRoot -ErrorAction Stop", first_install)
        self.assertIn("Write-InstallOwnershipMarker", first_install)
        self.assertNotIn("New-Item -ItemType Directory -Force -Path $InstallRoot", first_install)

    def test_install_root_that_appears_during_setup_is_revalidated_before_copy(self):
        first_install = self.installer.split("# First install: only write into a new or explicitly owned folder.", 1)[1].split("$copyArgs =", 1)[0]
        self.assertIn("the install folder appeared or changed during setup", first_install)
        self.assertIn("if (-not (Test-ManagedInstall))", first_install)

    def test_install_ownership_marker_checks_install_root_and_marker_reparse_points(self):
        function = self.installer.split("function Write-InstallOwnershipMarker", 1)[1].split("function Test-LegacyManagedInstall", 1)[0]
        self.assertIn("Get-Item -LiteralPath $InstallRoot", function)
        self.assertIn("$installRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint", function)
        self.assertIn("$markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint", function)

    def test_data_root_is_limited_to_two_known_locations_and_reparse_points_are_refused(self):
        self.assertIn("$driveHome = 'D:\\LocalAI'", self.data_path)
        self.assertIn("$driveData = Join-Path $driveHome 'CreativeStudioData'", self.data_path)
        self.assertIn("CreativeStudioData", self.data_path)
        self.assertIn("two supported CreativeStudioData locations", self.data_path)
        self.assertIn("ReparsePoint", self.data_path)
        self.assertIn("No cleanup or update was performed", self.data_path)

    def test_desktop_and_start_menu_collisions_are_never_replaced(self):
        self.assertIn("Get-SafeShortcutPath $Desktop", self.installer)
        self.assertIn("Get-SafeShortcutPath $StartMenu", self.installer)
        self.assertIn("No existing shortcut was changed", self.installer)
        self.assertIn(".ico'", self.installer)

    def test_runtime_install_is_per_user_and_does_not_change_system_python(self):
        self.assertIn("LocalAI\\CreativeStudioRuntime", self.installer)
        self.assertIn("InstallAllUsers=0", self.installer)
        self.assertIn("Include_launcher=0", self.installer)
        self.assertIn("PrependPath=0", self.installer)
        self.assertIn("AppendPath=0", self.installer)
        self.assertIn("AssociateFiles=0", self.installer)
        self.assertIn("Shortcuts=0", self.installer)

    def test_launcher_uses_fast_local_process_readiness_not_external_engine_health(self):
        self.assertIn("/api/ready", self.launcher)
        self.assertIn("@app.get(\"/api/ready\")", (ROOT / "studio" / "server.py").read_text(encoding="utf-8"))

    def test_update_does_not_remove_desktop_or_start_menu_items(self):
        self.assertNotRegex(self.updater, re.compile(r"Remove-Item[^\r\n]*(Desktop|StartMenu|\$Desktop|\$StartMenu)", re.I))
        self.assertNotIn("/MIR", self.updater.upper())
        self.assertIn("only when they still match their previous recorded SHA-256", self.updater)

    def test_update_cleanup_only_removes_marked_owned_stage_and_backup_folders(self):
        self.assertIn(".localai-update-owner.json", self.updater)
        self.assertIn("function Test-OwnedUpdateFolder", self.updater)
        self.assertIn("function Test-PlainUpdateTree", self.updater)
        self.assertIn("Remove-OwnedUpdateFolder $_.FullName", self.updater)
        self.assertNotRegex(self.updater, re.compile(r"Remove-Item[^\r\n]*UpdateRoot", re.I))

    def test_python_runtime_targets_are_never_overwritten_without_ownership(self):
        self.assertIn(".localai-python-runtime.json", self.installer)
        self.assertIn("The Python target already contains files but has no verified LocalAI ownership marker", self.installer)
        self.assertIn("Ensure-PlainDirectory $targetParent", self.installer)

    def test_new_shortcut_creation_is_atomic_and_cannot_clobber_a_racing_app(self):
        self.assertIn("[System.IO.File]::Move($temporary, $ShortcutPath)", self.installer)
        self.assertIn("The shortcut name became occupied by another program or user", self.installer)
        self.assertIn("Test-OwnedShortcut $ShortcutPath", self.installer)
        self.assertIn("[System.IO.File]::Replace($temporary, $ShortcutPath, $backup)", self.installer)
        self.assertIn("$backup = Join-Path $directory", self.installer)
        self.assertNotIn("$backup = Join-Path $BackupDirectory", self.installer)
        self.assertIn("File.Replace requires all", self.installer)

    def test_shortcut_directories_and_icon_cache_reject_reparse_points(self):
        self.assertIn("function Ensure-PlainDirectory", self.installer)
        self.assertIn("Ensure-PlainDirectory $Desktop", self.installer)
        self.assertIn("Ensure-PlainDirectory $StartMenu", self.installer)
        self.assertIn("Ensure-PlainDirectory $IconDir", self.installer)
        self.assertIn("$copiedHash -ne $IconHash", self.installer)

    def test_launcher_refuses_redirected_data_logs_and_browser_profile_paths(self):
        self.assertIn("Ensure-PlainDirectory $LogRoot", self.launcher)
        self.assertIn("Ensure-PlainDirectory $BrowserProfile", self.launcher)
        self.assertIn("Assert-PlainFileOrMissing $StdOut", self.launcher)
        self.assertIn("Assert-PlainFileOrMissing $PidFile", self.launcher)

    def test_manifest_builder_never_packages_symbolic_links(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        self.assertIn("if path.is_symlink():", builder)
        self.assertIn("self-contained", builder)

    def test_diagnostics_share_the_persisted_data_root(self):
        diagnostics = (ROOT / "scripts" / "CHECK-STUDIO.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("DATA-PATH.ps1", diagnostics)
        self.assertIn("Get-LocalAIDataRoot", diagnostics)
        self.assertIn("/api/ready", diagnostics)
        self.assertNotIn("D:\\LocalAI\\Logs", diagnostics)

    def test_python_runtime_marker_is_written_before_installer_and_ready_after_probe(self):
        marker_at = self.installer.index("state = 'INSTALLING'")
        start_at = self.installer.index("Start-Process -FilePath $installerPath")
        ready_at = self.installer.index("state = 'READY'")
        self.assertLess(marker_at, start_at)
        self.assertLess(start_at, ready_at)
        self.assertIn("'.localai-python-runtime.json'", self.installer)
        self.assertIn("$runtimeState -notin @('INSTALLING','READY')", self.installer)

    def test_python_installer_cache_is_content_addressed_and_never_deletes_generic_installer(self):
        self.assertIn("$expectedSha256.Substring(0,16)", self.installer)
        self.assertIn("[System.IO.File]::Move($downloadTemp, $installerPath)", self.installer)
        self.assertNotIn("Join-Path $DownloadRoot 'python-3.14.10-amd64.exe'", self.installer)
        self.assertNotIn("Remove-Item -LiteralPath $installerPath", self.installer)

    def test_python_runtime_marker_supports_legacy_ready_markers(self):
        self.assertIn("$runtimeRecord.PSObject.Properties.Name -contains 'state'", self.installer)
        self.assertIn("else { 'READY' }", self.installer)

    def test_programs_parent_is_checked_after_creation_before_install_copy(self):
        parent_check = self.installer.index('Ensure-PlainDirectory $installParent')
        copy = self.installer.index('& robocopy.exe @copyArgs')
        self.assertLess(parent_check, copy)
        self.assertIn('Refusing to write into a file, junction or symbolic link', self.installer)

    def test_owned_install_and_python_runtime_directories_fail_on_creation_race(self):
        self.assertIn("New-Item -ItemType Directory -Path $InstallRoot -ErrorAction Stop", self.installer)
        self.assertIn("New-Item -ItemType Directory -Path $targetDir -ErrorAction Stop", self.installer)
        self.assertNotIn("New-Item -ItemType Directory -Force -Path $InstallRoot", self.installer)
        self.assertNotIn("New-Item -ItemType Directory -Force -Path $targetDir", self.installer)

    def test_python_runtime_uses_new_managed_path_without_touching_legacy_partial_folders(self):
        self.assertIn("Python314-LocalAI", self.installer)
        self.assertIn("legacy-localappdata-primary", self.installer)
        self.assertIn("The Python target already contains files but has no verified LocalAI ownership marker", self.installer)


    def test_stop_and_diagnostics_resolve_only_marker_verified_installed_root(self):
        resolver = (ROOT / "scripts" / "INSTALL-ROOT.ps1").read_text(encoding="utf-8-sig")
        stop = (ROOT / "scripts" / "STOP-STUDIO.ps1").read_text(encoding="utf-8-sig")
        check = (ROOT / "scripts" / "CHECK-STUDIO.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(".localai-creative-studio-owner.json", resolver)
        self.assertIn("product_id -eq 'localai-creative-studio'", resolver)
        self.assertIn("schema_version -eq 1", resolver)
        self.assertIn("[IO.FileAttributes]::ReparsePoint", resolver)
        self.assertIn("Test-LocalAIPlainPackageTree", resolver)
        self.assertIn("Get-VerifiedLocalAIInstallRoot", stop)
        self.assertIn("Get-VerifiedLocalAIInstallRoot", check)

    def test_run_tests_can_use_installed_environment_when_started_from_release_folder(self):
        run_tests = (ROOT / "RUN-TESTS.bat").read_text(encoding="utf-8")
        self.assertIn("GET-VERIFIED-INSTALL-ROOT.ps1", run_tests)
        self.assertIn('-File "%RESOLVER%"', run_tests)
        self.assertIn("PROJECT_ROOT", run_tests)
        self.assertIn("unittest discover -s tests -v", run_tests)
        self.assertNotIn("INSTALLED_ROOT", run_tests)

    def test_installer_uses_explicit_windows_messagebox_enums_for_error_dialog(self):
        self.assertIn("MessageBoxButtons]::OK", self.installer)
        self.assertIn("MessageBoxIcon]::Error", self.installer)


    def test_installed_package_verifier_accepts_only_its_own_validated_owner_marker(self):
        verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(".localai-creative-studio-owner.json", verifier)
        self.assertIn("$ownerRecord.product_id -ne 'localai-creative-studio'", verifier)
        self.assertIn("$ownerRecord.schema_version -ne 1", verifier)
        self.assertIn("$savedRoot -ine $expectedRoot", verifier)
        self.assertIn("$_.FullName -ine $ownerMarker", verifier)

    def test_interrupted_staging_venvs_are_excluded_from_release_integrity(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertIn(".venv.next.incomplete-", builder)
        self.assertIn(r".venv\.next\.incomplete-", verifier)
        self.assertIn(".venv.next.incomplete-*/", gitignore)

    def test_python_bootstrap_omits_unneeded_utility_tools(self):
        self.assertIn("Include_tools=0", self.installer)
        self.assertIn("Include_dev=1", self.installer)
        self.assertIn("Include_pip=1", self.installer)



if __name__ == "__main__":
    unittest.main()
