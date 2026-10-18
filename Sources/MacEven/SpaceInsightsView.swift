import SwiftUI
import MacEvenCore

private typealias SpaceViewState<Value> = SwiftUI.State<Value>

struct SpaceFilterForm {
    var category: FileCategory? = nil
    var minMiB = ""
    var maxMiB = ""
    var days: Int? = nil

    func filter(now: Date = Date()) throws -> SpaceFilter {
        func allocated(_ text: String) throws -> Int64? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(value) else {
                throw MacEvenError(localized("占用大小请输入非负整数 MiB。"))
            }
            let (bytes, overflow) = number.multipliedReportingOverflow(by: 1_048_576)
            guard !overflow else { throw MacEvenError(localized("占用大小超出支持范围。")) }
            return bytes
        }
        var cutoff: Int64?
        if let days {
            guard [30,90,180,365].contains(days) else { throw MacEvenError(localized("请选择有效的未修改时间。")) }
            let value = (now.timeIntervalSince1970 - Double(days) * 86_400) * 1_000_000_000
            guard value.isFinite, value > 0, value < Double(Int64.max) else { throw MacEvenError(localized("修改时间超出支持范围。")) }
            cutoff = Int64(value)
        }
        return try SpaceFilter(category: category, minAllocated: allocated(minMiB), maxAllocated: allocated(maxMiB), notModifiedSince: cutoff)
    }
}

extension FileCategory {
    var title: String {
        switch self {
        case .other: localized("其他")
        case .image: localized("图片")
        case .video: localized("视频")
        case .audio: localized("音频")
        case .document: localized("文档")
        case .archive: localized("压缩包与镜像")
        case .source: localized("代码与配置")
        }
    }
}

struct SpaceInsightsView: View {
    @ObservedObject var model: AppModel
    @SpaceViewState private var form = SpaceFilterForm()
    @SpaceViewState private var inputError: String?
    private var total: Int64 { model.categoryStats.reduce(0) { $0 + $1.allocatedSize } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("当前范围全部已索引文件")).font(.headline)
                    ForEach(FileCategory.allCases, id: \.self) { category in
                        let stat = model.categoryStats.first { $0.category == category }
                        HStack(spacing: 8) {
                            Button(category.title) { form.category = category; apply() }
                                .buttonStyle(.evenLink).frame(width: 100, alignment: .leading)
                                .accessibilityLabel(localized("筛选\(category.title)"))
                            ProgressView(value: total > 0 ? min(1, Double(stat?.allocatedSize ?? 0) / Double(total)) : 0)
                                .progressViewStyle(.linear).frame(minWidth: 70)
                                .accessibilityLabel(category.title + localized("占用比例"))
                            Text(localized("\(stat?.count ?? 0) 项 · \(bytes(stat?.allocatedSize ?? 0))"))
                                .font(.caption).monospacedDigit().frame(width: 135, alignment: .trailing)
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Picker(localized("文件类型"), selection: $form.category) {
                        Text(localized("全部类型")).tag(FileCategory?.none)
                        ForEach(FileCategory.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    HStack {
                        TextField(localized("最小占用 MiB"), text: $form.minMiB).accessibilityLabel(localized("最小占用 MiB"))
                        Text(localized("至"))
                        TextField(localized("最大占用 MiB"), text: $form.maxMiB).accessibilityLabel(localized("最大占用 MiB"))
                    }.textFieldStyle(.roundedBorder)
                    Picker(localized("未修改时间"), selection: $form.days) {
                        Text(localized("不限")).tag(Int?.none)
                        ForEach([30,90,180,365], id: \.self) { Text(localized("至少 \($0) 天未修改")).tag(Optional($0)) }
                    }
                    HStack {
                        Button(localized("应用筛选"), action: apply).buttonStyle(.evenPrimary)
                        Button(localized("清空筛选")) { form = SpaceFilterForm(); inputError = nil; model.clearSpaceFilter() }
                        if model.loading { Button(localized("取消查询"), action: model.cancel) }
                    }
                    Text(localized("1 MiB = 1,048,576 字节；未修改不代表未使用。")).font(.caption).foregroundStyle(Theme.muted)
                    if let inputError { Text(inputError).font(.caption).foregroundStyle(Theme.destructive).accessibilityLabel(inputError) }
                }.frame(maxWidth: .infinity)
            }
            Text(localized("筛选匹配 \(model.filteredCount.formatted()) 项 · 占用估算 \(bytes(model.filteredAllocatedSize))"))
                .font(.callout).monospacedDigit()
            if let cutoff = model.spaceFilter.notModifiedSince {
                Text(localized("最近修改不晚于 \(Date(timeIntervalSince1970: Double(cutoff) / 1_000_000_000).formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: localizationLocale)))"))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .disabled(model.scanning || model.operating)
        .onAppear {
            form.category = model.spaceFilter.category
            form.minMiB = model.spaceFilter.minAllocated.map { String($0 / 1_048_576) } ?? ""
            form.maxMiB = model.spaceFilter.maxAllocated.map { String($0 / 1_048_576) } ?? ""
            if let cutoff = model.spaceFilter.notModifiedSince {
                let age = (Date().timeIntervalSince1970 - Double(cutoff) / 1_000_000_000) / 86_400
                form.days = [30,90,180,365].min { abs(Double($0) - age) < abs(Double($1) - age) }
            }
        }
    }
    private func apply() {
        do { let filter = try form.filter(); inputError = nil; model.applySpaceFilter(filter) }
        catch { inputError = error.localizedDescription }
    }
}
