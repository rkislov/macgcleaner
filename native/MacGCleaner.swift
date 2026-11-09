// Copyright 2026 Кислов Роман Сергеевич
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

struct Category: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let days: Int
    var symbol: String {
        switch id { case "caches": return "square.stack.3d.up"; case "logs": return "doc.text"; default: return "hammer" }
    }
}
struct CleanItem: Decodable, Identifiable {
    let id: String
    let category: String
    let name: String
    let path: String
    let bytes: Int64
    let files: Int
    let modified: String
}
struct Report: Decodable {
    let items: [CleanItem]
    let warnings: [String]
    let categories: [Category]
    let total: Int64
}
struct CleanFailure: Decodable { let id: String; let message: String }
struct CleanResult: Decodable { let moved: [String]; let failed: [CleanFailure]; let bytes: Int64 }
struct EngineError: Decodable { let error: String }
struct InstalledApp: Decodable, Identifiable {
    let id: String
    let name: String
    let path: String
    let bundleID: String
    let bytes: Int64
    let running: Bool
    var related: [CleanItem]
    var bundleRemoved = false
    enum CodingKeys: String, CodingKey { case id, name, path, bundleID, bytes, running, related }
}
struct AppReport: Decodable { let apps: [InstalledApp]; let warnings: [String] }

func sizeString(_ bytes: Int64) -> String {
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
    var value = Double(bytes), index = 0
    while value >= 1000 && index < units.count - 1 { value /= 1000; index += 1 }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.maximumFractionDigits = index == 0 ? 0 : 1
    return "\(formatter.string(from: NSNumber(value: value)) ?? "0") \(units[index])"
}

final class EngineClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacGCleaner.engine", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    func request<T: Decodable & Sendable>(_ command: String, ids: [String] = [], completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        queue.async { [self] in
            do {
                if process?.isRunning != true { try start() }
                var data = try JSONSerialization.data(withJSONObject: ["command": command, "ids": ids])
                data.append(10)
                try input!.write(contentsOf: data)
                while !buffer.contains(10) {
                    let chunk = output!.availableData
                    if chunk.isEmpty { throw NSError(domain: "MacGCleaner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Движок завершил работу. Повторите сканирование."]) }
                    buffer.append(chunk)
                }
                let index = buffer.firstIndex(of: 10)!
                let response = Data(buffer[..<index])
                buffer.removeSubrange(...index)
                if let error = try? JSONDecoder().decode(EngineError.self, from: response) {
                    throw NSError(domain: "MacGCleaner", code: 2, userInfo: [NSLocalizedDescriptionKey: error.error])
                }
                completion(.success(try JSONDecoder().decode(T.self, from: response)))
            } catch {
                process?.terminate()
                process = nil
                buffer.removeAll()
                completion(.failure(error))
            }
        }
    }

    private func start() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cleaner-engine")
        let task = Process()
        task.executableURL = url
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.standardError
        try task.run()
        process = task
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer.removeAll()
    }

    func stop() { process?.terminate() }
    deinit { stop() }
}

@MainActor final class CleanerModel: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var categories: [Category] = [
        Category(id: "caches", name: "Кэши приложений", description: "Не изменялись минимум 7 дней. Приложения создадут их заново.", days: 7),
        Category(id: "logs", name: "Старые журналы", description: "Диагностические логи старше 30 дней.", days: 30),
        Category(id: "xcode", name: "Сборки Xcode", description: "DerivedData старше 14 дней. Следующая сборка займёт больше времени.", days: 14)
    ]
    @Published var selected = Set<String>()
    @Published var category = "all"
    @Published var search = ""
    @Published var busy = false
    @Published var scanned = false
    @Published var status = "Готов к сканированию"
    @Published var warnings: [String] = []
    @Published var error: String?
    @Published var showConfirm = false
    @Published var showWarnings = false
    @Published var available: Int64 = 0
    @Published var capacity: Int64 = 1
    @Published var section = "cleaner"
    @Published var apps: [InstalledApp] = []
    @Published var appsScanned = false
    @Published var selectedApps = Set<String>()
    @Published var appWarnings: [String] = []
    private let engine = EngineClient()

    init() { refreshDisk() }
    var isApps: Bool { section == "apps" }
    var activeScanned: Bool { isApps ? appsScanned : scanned }
    var activeSelected: Set<String> { isApps ? selectedApps : selected }
    var activeWarnings: [String] { isApps ? appWarnings : warnings }
    var total: Int64 { isApps ? apps.reduce(0) { $0 + ($1.bundleRemoved ? 0 : $1.bytes) + $1.related.reduce(0) { $0 + $1.bytes } } : items.reduce(0) { $0 + $1.bytes } }
    var selectedBytes: Int64 {
        if isApps { return apps.reduce(0) { $0 + (selectedApps.contains($1.id) && !$1.bundleRemoved ? $1.bytes : 0) + $1.related.filter { selectedApps.contains($0.id) }.reduce(0) { $0 + $1.bytes } } }
        return items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
    var visibleApps: [InstalledApp] { apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) } }
    var visible: [CleanItem] {
        items.filter { (category == "all" || $0.category == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)) }
    }
    func refreshDisk() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            capacity = max((attrs[.systemSize] as? NSNumber)?.int64Value ?? 1, 1)
        }
    }
    func scan() {
        busy = true; selected.removeAll(); error = nil
        status = "Проверяем кэши, журналы и сборки…"
        engine.request("scan") { [weak self] (result: Result<Report, Error>) in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let report):
                    self.items = report.items; self.warnings = report.warnings; self.categories = report.categories
                    self.scanned = true; self.refreshDisk()
                    self.status = report.items.isEmpty ? "Старых файлов для очистки не найдено" : "Сканирование завершено · объектов: \(report.items.count)"
                case .failure(let error):
                    self.items = []; self.scanned = false
                    self.error = error.localizedDescription; self.status = "Не удалось завершить сканирование"
                }
            }
        }
    }
    func scanActive() { if isApps { scanApps() } else { scan() } }
    func scanApps() {
        busy = true; selectedApps.removeAll(); error = nil
        status = "Ищем программы и связанные файлы…"
        engine.request("apps") { [weak self] (result: Result<AppReport, Error>) in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let report):
                    self.apps = report.apps; self.appWarnings = report.warnings; self.appsScanned = true
                    self.status = "Поиск завершён · программ: \(report.apps.count)"; self.refreshDisk()
                case .failure(let error):
                    self.apps = []; self.appsScanned = false; self.error = error.localizedDescription
                    self.status = "Не удалось получить список программ"
                }
            }
        }
    }
    func clean() {
        guard !activeSelected.isEmpty, !busy else { return }
        let cleaningApps = isApps
        busy = true; status = "Переносим выбранное в Корзину…"
        engine.request("clean", ids: Array(activeSelected)) { [weak self] (result: Result<CleanResult, Error>) in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let report):
                    let moved = Set(report.moved)
                    self.items.removeAll { moved.contains($0.id) }
                    self.selected.subtract(moved)
                    self.selectedApps.subtract(moved)
                    for index in self.apps.indices {
                        if moved.contains(self.apps[index].id) { self.apps[index].bundleRemoved = true }
                        self.apps[index].related.removeAll { moved.contains($0.id) }
                    }
                    self.apps.removeAll { $0.bundleRemoved && $0.related.isEmpty }
                    self.status = "В Корзине: \(sizeString(report.bytes)) · объектов: \(report.moved.count)"
                    self.refreshDisk()
                    if !report.failed.isEmpty { self.error = report.failed.map(\.message).joined(separator: "\n\n") }
                case .failure(let error):
                    self.error = error.localizedDescription; self.status = "Очистка прервана. Выполните новое сканирование."
                    if cleaningApps { self.selectedApps.removeAll() } else { self.selected.removeAll() }
                }
            }
        }
    }
    func toggle(_ id: String) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }
    func toggleApp(_ id: String) { if selectedApps.contains(id) { selectedApps.remove(id) } else { selectedApps.insert(id) } }
    func toggleVisible() {
        let ids = Set(visible.map(\.id))
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
    func stop() { engine.stop() }
}

private let accent = Color(red: 0.12, green: 0.53, blue: 0.39)

@main struct MacGCleanerApp: App {
    @StateObject private var model = CleanerModel()
    var body: some Scene {
        WindowGroup("MacGCleaner") {
            CleanerView().environmentObject(model)
                .frame(minWidth: 1000, minHeight: 700)
                .tint(accent)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width: 1160, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Сканировать") { model.scanActive() }.keyboardShortcut("r").disabled(model.busy)
            }
        }
    }
}

struct CleanerView: View {
    @EnvironmentObject var model: CleanerModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                header
                HStack(spacing: 14) {
                    metric(model.isApps ? "ПРОГРАММЫ И ИХ ДАННЫЕ" : "НАЙДЕНО ДЛЯ ОЧИСТКИ", value: model.activeScanned ? sizeString(model.total) : "—", symbol: model.isApps ? "app.badge" : "sparkles", note: model.isApps ? "Программ: \(model.apps.count)" : "Только старые данные", highlighted: true)
                    metric("ВЫБРАНО", value: sizeString(model.selectedBytes), symbol: "checkmark.circle", note: "Объектов: \(model.activeSelected.count)")
                    metric("СВОБОДНО НА ДИСКЕ", value: sizeString(model.available), symbol: "internaldrive", note: "Всего \(sizeString(model.capacity))")
                }
                if model.isApps { appResults } else { categories; results }
                footer
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .alert("Переместить выбранное в Корзину?", isPresented: $model.showConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("В Корзину", role: .destructive) { model.clean() }
        } message: {
            Text(model.isApps
                 ? "Объектов: \(model.activeSelected.count), размер: \(sizeString(model.selectedBytes)). Выбранные программы и отмеченные связанные файлы будут перемещены в Корзину. Связанные файлы могут содержать настройки, сессии и пользовательские данные. Выбирайте их только если они больше не нужны."
                 : "Объектов: \(model.activeSelected.count), размер: \(sizeString(model.selectedBytes)). Закройте приложения, чьи кэши выбраны. Файлы останутся в Корзине; место освободится после её очистки в Finder.")
        }
        .alert("Не все действия выполнены", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showWarnings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Отчёт сканирования").font(.title2.bold())
                Text(model.isApps ? "Системные программы Apple и сама утилита исключены. Связанные данные ищутся по точному идентификатору приложения. Общие контейнеры не сканируются." : "Недоступные папки, ссылки и специальные файлы пропускаются. Папки с недавно изменёнными файлами также не попадают в список.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.activeWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.callout).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("Готово") { model.showWarnings = false }.keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 600, height: 380)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "leaf.fill").font(.title2).foregroundStyle(accent)
                Text("MacGCleaner").font(.system(size: 18, weight: .bold))
            }.padding(.top, 26)
            VStack(alignment: .leading, spacing: 8) {
                Text("ВАШ MAC").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12)
                navigation("cleaner", title: "Очистка", symbol: "sparkles")
                navigation("apps", title: "Удаление программ", symbol: "app.badge")
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Локально на вашем Mac", systemImage: "desktopcomputer")
                Label("Без доступа к сети", systemImage: "network.slash")
                Label("Без прав администратора", systemImage: "lock.shield")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "externaldrive.badge.checkmark").font(.title2).foregroundStyle(accent)
                Text("Контроль в ваших руках").font(.system(size: 13, weight: .semibold))
                Text("Выберите файлы перед очисткой. Всё выбранное отправится в Корзину macOS.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(16).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            HStack { Text("GO + SWIFTUI"); Spacer(); Text("1.0") }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 210).frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }

    private func navigation(_ section: String, title: String, symbol: String) -> some View {
        Button { model.section = section; model.search = "" } label: {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.section == section ? accent : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(model.section == section ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).disabled(model.busy)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.isApps ? "Программы — вместе со следами." : "Больше места. Меньше лишнего.").font(.system(size: 27, weight: .bold))
                Text(model.isApps ? "Удаляйте приложения и выбирайте, какие данные убрать вместе с ними." : "Найдите старые кэши и временные данные на вашем Mac.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.scanActive) {
                Label(model.busy ? "Обработка…" : (model.activeScanned ? "Сканировать снова" : (model.isApps ? "Найти программы" : "Сканировать Mac")), systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).disabled(model.busy).keyboardShortcut("r")
        }.padding(.top, 14)
    }

    private func metric(_ title: String, value: String, symbol: String, note: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(title).font(.system(size: 9, weight: .semibold)); Spacer(); Image(systemName: symbol).font(.system(size: 15)) }.foregroundStyle(highlighted ? accent : .secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(highlighted ? accent.opacity(0.2) : Color.primary.opacity(0.07)))
    }

    private var categories: some View {
        HStack(spacing: 10) {
            categoryButton(id: "all", name: "Все категории", symbol: "square.grid.2x2", subtitle: "Объектов: \(model.items.count)")
            ForEach(model.categories) { category in
                categoryButton(id: category.id, name: category.name, symbol: category.symbol, subtitle: "Старше \(category.days) дн.")
                    .help(category.description)
            }
        }.disabled(model.busy)
    }

    private func categoryButton(id: String, name: String, symbol: String, subtitle: String) -> some View {
        Button { model.category = id } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(model.category == id ? accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity)
                .background(model.category == id ? accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(model.category == id ? accent.opacity(0.4) : Color.primary.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Найденные объекты").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.items.isEmpty {
                    Button("Выбрать все в списке", action: model.toggleVisible).font(.system(size: 11)).buttonStyle(.link).disabled(model.busy)
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск", text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(7).frame(width: 145).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }.padding(15)
            Divider()
            if model.busy {
                VStack(spacing: 18) {
                    ProgressView().controlSize(.large)
                    Text(model.status).font(.system(size: 14, weight: .medium))
                    Text("Проверяем метаданные файлов. Личные документы не сканируются.").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: model.scanned ? "checkmark.seal" : "sparkle.magnifyingglass")
                        .font(.system(size: 43, weight: .light)).foregroundStyle(accent).padding(.bottom, 4)
                    Text(model.scanned ? (model.items.isEmpty ? "Старый мусор не найден" : "Ничего не найдено") : "Начнём с проверки").font(.system(size: 19, weight: .semibold))
                    Text(model.scanned ? "Попробуйте другую категорию или посмотрите отчёт сканирования." : "Сканирование покажет, что можно отправить в Корзину.\nВы сами решаете, какие файлы убрать.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                    if !model.scanned { Button("Сканировать Mac", action: model.scan).buttonStyle(.bordered).padding(.top, 4) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(22)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { item in
                            itemRow(item)
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            if model.scanned && !model.busy {
                Divider()
                HStack {
                    Label("Объектов в списке: \(model.visible.count)", systemImage: "line.3.horizontal.decrease")
                    Spacer()
                    if !model.warnings.isEmpty { Button("Пропуски: \(model.warnings.count)") { model.showWarnings = true }.buttonStyle(.link) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func itemRow(_ item: CleanItem) -> some View {
        HStack(spacing: 12) {
            Toggle("Выбрать \(item.name)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { _ in model.toggle(item.id) }))
                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Выбрать \(item.name)")
            Image(systemName: model.categories.first(where: { $0.id == item.category })?.symbol ?? "folder")
                .font(.system(size: 19)).foregroundStyle(accent).frame(width: 32, height: 35)
                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                Text(sizeString(item.bytes)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text("Файлов: \(item.files)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).help("Показать в Finder").accessibilityLabel("Показать \(item.name) в Finder")
        }.padding(.horizontal, 16).padding(.vertical, 12)
            .background(model.selected.contains(item.id) ? accent.opacity(0.04) : .clear)
            .help(item.path)
    }

    private var appResults: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Установленные программы").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Название программы", text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(7).frame(width: 200).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
            }.padding(15)
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle").foregroundStyle(accent)
                Text("Связанные файлы выбираются отдельно: в них могут быть настройки и личные данные. Системные приложения Apple исключены.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(accent.opacity(0.04))
            if model.busy {
                VStack(spacing: 18) { ProgressView().controlSize(.large); Text(model.status).font(.callout) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleApps.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "app.badge").font(.system(size: 43, weight: .light)).foregroundStyle(accent)
                    Text(model.appsScanned ? "Программы не найдены" : "Что больше не нужно?").font(.system(size: 19, weight: .semibold))
                    Text("Поиск в /Applications и ~/Applications.\nВыберите программу, затем проверьте связанные файлы.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                    if !model.appsScanned { Button("Найти программы", action: model.scanApps).buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleApps) { app in
                            applicationRow(app)
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }
            if model.appsScanned && !model.busy {
                Divider()
                HStack {
                    Text("Программ в списке: \(model.visibleApps.count)")
                    Spacer()
                    if !model.appWarnings.isEmpty { Button("Отчёт · \(model.appWarnings.count)") { model.showWarnings = true }.buttonStyle(.link) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func applicationRow(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle("Удалить \(app.name)", isOn: Binding(get: { model.selectedApps.contains(app.id) }, set: { _ in model.toggleApp(app.id) }))
                    .labelsHidden().toggleStyle(.checkbox).disabled(app.running || app.bundleRemoved)
                    .accessibilityLabel("Удалить \(app.name)")
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(app.name).font(.system(size: 13, weight: .semibold))
                        if app.running { Text("Запущена — закройте перед удалением").font(.system(size: 10)).foregroundStyle(.orange) }
                        if app.bundleRemoved { Text("Программа в Корзине").font(.system(size: 10)).foregroundStyle(accent) }
                    }
                    Text(app.bundleID).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(app.bundleRemoved ? "В Корзине" : sizeString(app.bytes)).font(.system(size: 12, weight: .semibold))
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless).help("Показать программу в Finder").disabled(app.bundleRemoved)
            }
            if !app.related.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(app.related) { item in
                            HStack(spacing: 9) {
                                Toggle("Выбрать \(item.path)", isOn: Binding(get: { model.selectedApps.contains(item.id) }, set: { _ in model.toggleApp(item.id) }))
                                    .labelsHidden().toggleStyle(.checkbox).disabled(app.running).accessibilityLabel("Выбрать \(item.path)")
                                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).help(item.path)
                                Spacer()
                                Text(sizeString(item.bytes)).font(.system(size: 10)).foregroundStyle(.secondary)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("Показать связанный файл в Finder")
                            }
                        }
                    }.padding(.top, 8)
                } label: {
                    Text("Связанные файлы: \(app.related.count) · \(sizeString(app.related.reduce(0) { $0 + $1.bytes }))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.leading, 26)
            } else {
                Text("Связанные файлы по идентификатору не найдены").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 26)
            }
        }.padding(16).background(model.selectedApps.contains(app.id) ? accent.opacity(0.04) : .clear)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("Место освободится после очистки Корзины в Finder.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { model.showConfirm = true } label: {
                Label("В Корзину · \(sizeString(model.selectedBytes))", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 9)
            }.buttonStyle(.borderedProminent).disabled(model.activeSelected.isEmpty || model.busy)
        }
    }
}
