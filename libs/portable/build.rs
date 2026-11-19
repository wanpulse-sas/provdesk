fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=RUSTDESK_APP_NAME");
    println!("cargo:rerun-if-env-changed=RUSTDESK_EDITOR_NAME");
    #[cfg(windows)]
    {
        println!("cargo:rerun-if-env-changed=BITBUCKET_BUILD_NUMBER");
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        if let Ok(app_name) = std::env::var("RUSTDESK_APP_NAME") {
            res.set("ProductName", &app_name)
                .set("OriginalFilename", &format!("{app_name}.exe"))
                .set("FileDescription", &format!("{app_name} Remote Desktop"));
        }
        if let Ok(editor) = std::env::var("RUSTDESK_EDITOR_NAME") {
            res.set("CompanyName", &editor);
        }
        match std::env::var("BITBUCKET_BUILD_NUMBER") {
            Ok(value) => {
                let build = value.parse::<u16>().map_err(|_| {
                    format!("BITBUCKET_BUILD_NUMBER must be an integer between 0 and 65535: {value}")
                })?;
                let major = env!("CARGO_PKG_VERSION_MAJOR").parse::<u16>()?;
                let minor = env!("CARGO_PKG_VERSION_MINOR").parse::<u16>()?;
                let patch = env!("CARGO_PKG_VERSION_PATCH").parse::<u16>()?;
                let version = (u64::from(major) << 48)
                    | (u64::from(minor) << 32)
                    | (u64::from(patch) << 16)
                    | u64::from(build);
                res.set_version_info(winres::VersionInfo::FILEVERSION, version)
                    .set("FileVersion", &format!("{major}.{minor}.{patch}.{build}"));
            }
            Err(std::env::VarError::NotPresent) => {}
            Err(error) => return Err(error.into()),
        }
        res.compile()?;
    }
    Ok(())
}
