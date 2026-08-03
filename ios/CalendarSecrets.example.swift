// ============================================================
// CalendarSecrets.example.swift — 模板，不参与编译（不在 Sources 目录里）。
//
// 拿到这份工程之后：把这个文件复制到 Sources/CalendarSecrets.swift，
// 把下面两个值换成自己的，就能连上自己的后端。
//
// 说清楚一件事：打包出来的 .app 里这串 token 是能被扒出来的。
// .gitignore 挡住的只是「源码分享出去不带钥匙」，不是「拿到安装包的人翻不出来」。
// 真要那一层安全得后端改成一人一把、能吊销的 key，那是后端的活。
// ============================================================

enum CalendarSecrets {
    static let token = "在这儿填你自己的 X-Calendar-Token"
    static let baseURL = "https://你的域名/api/v1/calendar"
}
