import Foundation

// 用途规则表：只是数据。标题只说用途，不重复名称；“勿动”规则一律 opaque。
extension PurposeRule {
    public static let builtIn: [PurposeRule] = system + applications + home + library + developer + projects + files + developerCleanup

    private static func at(_ id: String, _ path: String, _ category: PurposeCategory, _ safety: PurposeSafety, _ title: String, _ detail: String,
        opaque: Bool = false, heritable: Bool = true) -> PurposeRule {
        PurposeRule(id: id, match: .path(path), category: category, safety: safety, title: title, detail: detail, opaque: opaque, heritable: heritable)
    }
    private static func named(_ id: String, _ name: String, when condition: Condition? = nil, kind: Kind = .directory, _ category: PurposeCategory,
        _ safety: PurposeSafety, _ title: String, _ detail: String, opaque: Bool = true) -> PurposeRule {
        PurposeRule(id: id, match: .name(name), kind: kind, condition: condition, category: category, safety: safety, title: title, detail: detail, opaque: opaque)
    }
    private static func ext(_ id: String, _ ext: String, kind: Kind, _ category: PurposeCategory, _ safety: PurposeSafety, _ title: String, _ detail: String, opaque: Bool = false) -> PurposeRule {
        PurposeRule(id: id, match: .pathExtension(ext), kind: kind, category: category, safety: safety, title: title, detail: detail, opaque: opaque)
    }

    static let system: [PurposeRule] = [
        at("sys.system", "/System", .system, .keep, localized("macOS 系统"), localized("macOS 系统卷内容，受系统只读保护，不能也不需要清理。"), opaque: true),
        at("sys.usr", "/usr", .system, .keep, localized("系统命令与库"), localized("macOS 自带的命令行工具和系统库。")),
        at("sys.bin", "/bin", .system, .keep, localized("系统命令"), localized("macOS 基础命令行工具。"), opaque: true),
        at("sys.sbin", "/sbin", .system, .keep, localized("系统命令"), localized("macOS 系统管理命令。"), opaque: true),
        at("sys.vm", "/private/var/vm", .system, .keep, localized("虚拟内存"), localized("交换文件与休眠镜像，由系统按需创建和回收，不能手动删除。"), opaque: true),
        at("sys.db", "/private/var/db", .system, .keep, localized("系统数据库"), localized("系统服务的配置与状态数据。"), opaque: true),
        at("sys.folders", "/private/var/folders", .system, .caution, localized("系统临时目录"), localized("各应用的临时文件和缓存，由系统管理，重启或空间不足时会部分清理；不建议手动整体删除。")),
        at("sys.log", "/private/var/log", .log, .caution, localized("系统日志"), localized("系统与服务的日志，系统会自动轮换。")),
        at("sys.cores", "/cores", .system, .caution, localized("崩溃内存转储"), localized("程序崩溃时生成的内存转储，用于调试；不调试时通常可以删除。")),
        at("sys.volumes", "/Volumes", .system, .caution, localized("其他磁盘"), localized("外接磁盘和其他卷的挂载位置。"), heritable: false),
        at("sys.users", "/Users", .system, .caution, localized("用户主目录"), localized("这台 Mac 上各个用户的个人文件夹。"), heritable: false),
        at("sys.private", "/private", .system, .caution, localized("系统私有目录"), localized("系统的临时文件、配置和服务数据。")),
        at("sys.tmp", "/private/tmp", .system, .caution, localized("临时文件"), localized("程序运行时的临时文件，系统重启时会清理。")),
        at("sys.etc", "/private/etc", .system, .keep, localized("系统配置"), localized("系统与网络的配置文件。"), opaque: true),
        at("sys.opt", "/opt", .application, .caution, localized("第三方软件"), localized("第三方软件（如 Homebrew）的安装位置。")),
        at("sys.library", "/Library", .system, .caution, localized("系统级共享资源"), localized("所有用户共享的应用支持文件、驱动、字体和设置。")),
        at("sys.library.as", "/Library/Application Support", .appData, .caution, localized("共享应用数据"), localized("应用为所有用户保存的数据与组件。")),
        at("sys.library.caches", "/Library/Caches", .cache, .caution, localized("系统级缓存"), localized("系统和应用为所有用户保存的缓存。")),
        at("sys.library.logs", "/Library/Logs", .log, .regenerable, localized("系统级日志"), localized("系统和应用的运行日志，用于排查问题，删除不影响使用。")),
        at("sys.library.fonts", "/Library/Fonts", .system, .caution, localized("共享字体"), localized("为所有用户安装的字体，删除后使用这些字体的文稿会显示异常。")),
        at("sys.simruntimes", "/Library/Developer/CoreSimulator", .developer, .caution, localized("模拟器运行时"), localized("Xcode 下载的各版本 iOS 等模拟器系统镜像，每个可达数 GB；用 xcrun simctl runtime delete 或 Xcode 设置删除不需要的版本。"), opaque: true),
        at("sys.clt", "/Library/Developer/CommandLineTools", .developer, .caution, localized("Xcode 命令行工具"), localized("git、clang 等开发命令行工具；删除后需要用 xcode-select --install 重新安装。"), opaque: true),
    ]

    static let applications: [PurposeRule] = [
        at("app.applications", "/Applications", .application, .caution, localized("应用程序"), localized("已安装的应用。卸载应用请使用「软件」页，它会一并处理相关数据。")),
        at("app.user", "~/Applications", .application, .caution, localized("应用程序"), localized("只为当前用户安装的应用。卸载应用请使用「软件」页。")),
        ext("app.bundle", "app", kind: .directory, .application, .caution, localized("应用程序"), localized("应用包。直接删除只会移除程序本身，设置和缓存会残留；建议使用「软件」页卸载。"), opaque: true),
        at("app.homebrew", "/opt/homebrew", .developer, .caution, "Homebrew", localized("Homebrew 包管理器及其安装的命令行工具。请用 brew uninstall 或 brew cleanup 管理，不要手动删除。")),
        at("app.homebrew.cellar", "/opt/homebrew/Cellar", .developer, .caution, localized("Homebrew 软件包"), localized("Homebrew 已安装的各个软件包版本；旧版本可用 brew cleanup 清理。"), opaque: true),
        at("app.usrlocal", "/usr/local", .developer, .caution, localized("手动安装的工具"), localized("Intel Mac 上的 Homebrew，或手动安装的命令行工具与库。")),
    ]

    static let home: [PurposeRule] = [
        at("home.desktop", "~/Desktop", .userFiles, .caution, localized("你的桌面文件"), localized("你自己放在桌面上的文件，MacEven 无法判断是否还需要。")),
        at("home.documents", "~/Documents", .userFiles, .caution, localized("你的文稿"), localized("你自己的文稿，MacEven 无法判断是否还需要。")),
        at("home.downloads", "~/Downloads", .userFiles, .caution, localized("下载的文件"), localized("从浏览器等处下载的文件，常有已安装完的安装包和重复下载，值得定期整理。")),
        at("home.pictures", "~/Pictures", .userFiles, .caution, localized("你的图片"), localized("你自己的图片与图库。")),
        at("home.movies", "~/Movies", .userFiles, .caution, localized("你的影片"), localized("你自己的视频与剪辑工程。")),
        at("home.music", "~/Music", .userFiles, .caution, localized("你的音乐"), localized("你自己的音乐与「音乐」App 资料库。")),
        at("home.trash", "~/.Trash", .system, .caution, localized("废纸篓"), localized("已移到废纸篓的文件，在 Finder 中清空废纸篓后才会释放空间。"), opaque: true),
        ext("home.photos", "photoslibrary", kind: .directory, .userFiles, .keep, localized("照片图库"), localized("「照片」App 的图库，包含所有照片和编辑记录；请只在「照片」App 中管理。"), opaque: true),
    ]

    static let library: [PurposeRule] = [
        at("lib.root", "~/Library", .appData, .caution, localized("应用数据与设置"), localized("各应用保存的设置、数据和缓存，不要整体删除。")),
        at("lib.caches", "~/Library/Caches", .cache, .regenerable, localized("应用缓存"), localized("应用为加快速度保存的临时数据，删除后会自动重建；应用运行时删除可能出错。")),
        at("lib.caches.app", "~/Library/Caches/{app}", .cache, .regenerable, localized("{app} 缓存"), localized("{app} 为加快速度保存的临时数据，删除后会自动重建。")),
        at("lib.as", "~/Library/Application Support", .appData, .caution, localized("应用数据"), localized("应用保存的数据库、账户和下载内容等；删除可能导致应用丢失数据或需要重新登录。")),
        at("lib.as.app", "~/Library/Application Support/{appName}", .appData, .caution, localized("{app} 数据"), localized("{app} 保存的数据，可能包含账户、聊天记录或下载内容。卸载请使用「软件」页。")),
        at("lib.containers", "~/Library/Containers", .appData, .caution, localized("沙盒应用数据"), localized("沙盒应用各自的设置、文档和缓存。")),
        at("lib.containers.app", "~/Library/Containers/{app}", .appData, .caution, localized("{app} 沙盒数据"), localized("{app} 的沙盒，里面有它的设置、文档和缓存。卸载请使用「软件」页。")),
        at("lib.containers.cache", "~/Library/Containers/{app}/Data/Library/Caches", .cache, .regenerable, localized("{app} 缓存"), localized("{app} 为加快速度保存的临时数据，删除后会自动重建。")),
        at("lib.wechat", "~/Library/Containers/com.tencent.xinWeChat", .userFiles, .keep, localized("微信聊天记录"), localized("微信的聊天记录、图片、视频和文件；请在微信「设置 › 存储空间」中清理。"), opaque: true),
        at("lib.group", "~/Library/Group Containers", .appData, .caution, localized("应用共享数据"), localized("同一开发者的多个应用或扩展共用的数据。")),
        at("lib.group.app", "~/Library/Group Containers/{app}", .appData, .caution, localized("{app} 共享数据"), localized("{app} 与其扩展共用的数据，常包含聊天记录、文档等。")),
        at("lib.prefs", "~/Library/Preferences", .appData, .caution, localized("应用设置"), localized("各应用的偏好设置文件，体积很小；删除会让应用恢复默认设置。")),
        at("lib.logs", "~/Library/Logs", .log, .regenerable, localized("应用日志"), localized("应用运行日志，用于排查问题，删除不影响使用。")),
        at("lib.crash", "~/Library/Logs/DiagnosticReports", .log, .regenerable, localized("崩溃报告"), localized("应用崩溃和卡顿时生成的报告，删除不影响使用。")),
        at("lib.state", "~/Library/Saved Application State", .appData, .regenerable, localized("窗口恢复状态"), localized("应用重新打开时恢复窗口用的数据，删除后只是不再恢复上次的窗口。")),
        at("lib.http", "~/Library/HTTPStorages", .cache, .caution, localized("网络存储"), localized("应用的网络 Cookie 与缓存，删除后可能需要重新登录。")),
        at("lib.webkit", "~/Library/WebKit", .cache, .caution, localized("网页内容数据"), localized("应用内嵌网页的缓存与本地存储，删除后可能需要重新登录。")),
        at("lib.mail", "~/Library/Mail", .userFiles, .keep, localized("邮件数据"), localized("「邮件」App 的邮件与附件；请在「邮件」App 中管理。"), opaque: true),
        at("lib.messages", "~/Library/Messages", .userFiles, .keep, localized("信息记录"), localized("「信息」App 的聊天记录与附件；可在「信息」设置里设定保留期限。"), opaque: true),
        at("lib.icloud", "~/Library/Mobile Documents", .cloud, .keep, localized("iCloud 云盘"), localized("iCloud 云盘中的文件；删除会同步删除所有设备上的文件。"), opaque: true),
        at("lib.cloudstorage", "~/Library/CloudStorage", .cloud, .keep, localized("第三方云盘"), localized("OneDrive、Dropbox、Google 云端硬盘等的同步文件夹；删除会同步到云端。"), opaque: true),
        at("lib.mobilesync", "~/Library/Application Support/MobileSync/Backup", .backup, .caution, localized("iPhone/iPad 备份"), localized("在这台 Mac 上做的设备本地备份，可在 Finder 的设备页面管理；确认不需要后再删除。"), opaque: true),
        at("lib.chrome", "~/Library/Application Support/Google/Chrome", .appData, .keep, localized("Chrome 用户数据"), localized("书签、密码、扩展和历史记录；清理缓存请使用「缓存/AI清理」页。"), opaque: true),
        at("lib.developer", "~/Library/Developer", .developer, .caution, localized("开发者数据"), localized("Xcode、模拟器等开发工具的数据。")),
    ]

    static let developer: [PurposeRule] = [
        at("dev.archives", "~/Library/Developer/Xcode/Archives", .developer, .caution, localized("Xcode 归档"), localized("上架或分发时生成的归档，含调试符号，用于分析线上崩溃；确认不需要再删除。"), opaque: true),
        at("dev.simdevices", "~/Library/Developer/CoreSimulator/Devices", .developer, .caution, localized("模拟器设备"), localized("各个模拟器的系统和已装 App 数据；可用 xcrun simctl delete unavailable 清理失效设备。"), opaque: true),
        at("dev.cargo", "~/.cargo", .developer, .caution, localized("Rust 工具与依赖"), localized("cargo 安装的工具和下载的依赖。")),
        at("dev.rustup", "~/.rustup", .developer, .caution, localized("Rust 工具链"), localized("rustup 安装的编译器版本；不用的版本可用 rustup toolchain uninstall 删除。"), opaque: true),
        at("dev.npm", "~/.npm", .cache, .regenerable, localized("npm 缓存"), localized("npm 的下载缓存、日志和 npx 临时包，删除后按需重新生成。")),
        at("dev.m2", "~/.m2/repository", .developer, .caution, localized("Maven 本地仓库"), localized("Maven 下载的依赖，以及 mvn install 安装的本地模块；后者若没有发布到远端，删除后无法重新下载。"), opaque: true),
        at("dev.cache", "~/.cache", .cache, .regenerable, localized("命令行工具缓存"), localized("各种命令行工具的缓存，删除后按需重建；其中的模型文件需要重新下载。")),
        at("dev.huggingface", "~/.cache/huggingface", .developer, .caution, localized("Hugging Face 模型缓存"), localized("下载过的 AI 模型与数据集，单个可达数十 GB；删除后需要重新下载。"), opaque: true),
        at("dev.gradlewrapper", "~/.gradle/wrapper/dists", .cache, .regenerable, localized("Gradle 发行包"), localized("各项目用过的 Gradle 版本，删除后构建时按需重新下载。"), opaque: true),
        at("dev.orbstack", "~/.orbstack", .developer, .caution, localized("OrbStack 容器与虚拟机"), localized("OrbStack 的容器、镜像和 Linux 虚拟机磁盘；请在 OrbStack 中清理。"), opaque: true),
        at("dev.nvm", "~/.nvm", .developer, .caution, localized("Node 版本管理"), localized("nvm 安装的各个 Node.js 版本。"), opaque: true),
        at("dev.pyenv", "~/.pyenv", .developer, .caution, localized("Python 版本管理"), localized("pyenv 安装的各个 Python 版本。"), opaque: true),
        at("dev.gomod", "~/go/pkg/mod", .cache, .regenerable, localized("Go 模块缓存"), localized("删除后需要联网重新下载；建议用 go clean -modcache 清理。"), opaque: true),
        at("dev.docker", "~/.docker", .developer, .caution, localized("Docker 配置"), localized("Docker 命令行的配置与上下文。")),
        at("dev.dockervm", "~/Library/Containers/com.docker.docker", .developer, .caution, localized("Docker 虚拟磁盘"), localized("Docker Desktop 的镜像、容器和数据卷；请用 docker system prune 或 Docker Desktop 清理。"), opaque: true),
        at("dev.ollama", "~/.ollama/models", .developer, .caution, localized("Ollama 模型"), localized("本地大模型文件，删除后需要重新下载；建议用 ollama rm 管理。"), opaque: true),
        at("dev.vscode", "~/.vscode/extensions", .developer, .caution, localized("VS Code 扩展"), localized("已安装的 VS Code 扩展，删除后需要重新安装。"), opaque: true),
    ]

    static let projects: [PurposeRule] = [
        named("proj.node_modules", "node_modules", when: .siblingAny(["package.json"]), .buildArtifact, .regenerable, localized("npm 依赖"), localized("项目「{parent}」的依赖包，删除后在项目里执行 npm install 可恢复。")),
        named("proj.cargo", "target", when: .siblingAny(["Cargo.toml"]), .buildArtifact, .regenerable, localized("Rust 构建产物"), localized("项目「{parent}」的编译输出，删除后重新 cargo build 即可。")),
        named("proj.swiftpm", ".build", when: .siblingAny(["Package.swift"]), .buildArtifact, .regenerable, localized("Swift 构建产物"), localized("项目「{parent}」的编译输出，删除后重新构建即可。")),
        named("proj.pods", "Pods", when: .siblingAny(["Podfile"]), .buildArtifact, .regenerable, localized("CocoaPods 依赖"), localized("项目「{parent}」的依赖，删除后执行 pod install 可恢复。")),
        named("proj.build", "build", when: .siblingAny(["build.gradle", "build.gradle.kts", "CMakeLists.txt"]), .buildArtifact, .regenerable, localized("构建产物"), localized("项目「{parent}」的编译输出，删除后重新构建即可。")),
        named("proj.dist", "dist", when: .siblingAny(["package.json"]), .buildArtifact, .regenerable, localized("前端构建产物"), localized("项目「{parent}」打包输出，删除后重新构建即可。")),
        named("proj.next", ".next", when: .siblingAny(["package.json"]), .buildArtifact, .regenerable, localized("Next.js 构建缓存"), localized("项目「{parent}」的 Next.js 构建输出，删除后重新构建即可。")),
        named("proj.venv", ".venv", when: .childAny(["pyvenv.cfg"]), .buildArtifact, .caution, localized("Python 虚拟环境"), localized("项目「{parent}」的独立 Python 环境；有依赖清单时可重新创建，没有清单时删除后难以还原。")),
        named("proj.venv2", "venv", when: .childAny(["pyvenv.cfg"]), .buildArtifact, .caution, localized("Python 虚拟环境"), localized("项目「{parent}」的独立 Python 环境；有依赖清单时可重新创建，没有清单时删除后难以还原。")),
        named("proj.pycache", "__pycache__", .buildArtifact, .regenerable, localized("Python 字节码缓存"), localized("Python 运行时自动生成，删除后会重新生成。")),
        named("proj.git", ".git", .developer, .keep, localized("Git 版本历史"), localized("仓库的全部提交历史，删除后无法恢复历史记录。")),
        named("proj.cachedir", "*", when: .childAny(["CACHEDIR.TAG"]), .cache, .regenerable, localized("工具缓存"), localized("目录中有 CACHEDIR.TAG，表示创建它的工具声明这是可重建的缓存。")),
    ]

    static let files: [PurposeRule] = [
        named("file.dsstore", ".DS_Store", kind: .file, .appData, .regenerable, localized("Finder 显示设置"), localized("记录图标位置等显示设置，体积很小，删除后 Finder 会重新生成。"), opaque: false),
        ext("file.dmg", "dmg", kind: .file, .installer, .caution, localized("磁盘映像"), localized("通常是软件安装包；安装完成后一般可以删除。")),
        ext("file.pkg", "pkg", kind: .any, .installer, .caution, localized("安装包"), localized("软件安装包；安装完成后一般可以删除。"), opaque: true),
        ext("file.ipsw", "ipsw", kind: .file, .installer, .caution, localized("iOS 固件"), localized("设备恢复或升级用的固件；Apple 停止签名后旧版本即使重新下载也无法使用。")),
        ext("file.xip", "xip", kind: .file, .installer, .caution, localized("Xcode 安装包"), localized("Xcode 等 Apple 软件的压缩安装包；解压安装后一般可以删除。")),
        ext("file.iso", "iso", kind: .file, .installer, .caution, localized("光盘映像"), localized("系统或软件的光盘映像，常用于虚拟机安装。")),
        ext("file.sparsebundle", "sparsebundle", kind: .directory, .backup, .caution, localized("磁盘映像"), localized("可增长的磁盘映像，常用于时间机器备份或加密存储。"), opaque: true),
        ext("file.xcarchive", "xcarchive", kind: .directory, .developer, .caution, localized("Xcode 归档"), localized("上架或分发时生成的归档，含调试符号。"), opaque: true),
    ]

    // 与「缓存/AI清理」的开发者缓存规则同源，保证两处说法一致。
    static let developerCleanup: [PurposeRule] = DeveloperCleanupRule.allCases.map { rule in
        at("dev.cleanup.\(rule.rawValue)", "~/" + rule.relativePath, .cache, .regenerable, rule.name,
            localized("由工具自动管理的缓存，可在「缓存/AI清理」中清理；删除后：\(rule.rebuildCost)。"), opaque: true)
    }
}
