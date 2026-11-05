import SwiftUI
import SetcheckCore

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 35)).foregroundStyle(.red).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setcheck").font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("Видео и треклист для проверки на YouTube").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Как это работает", systemImage: "questionmark.circle") { model.showHelp = true }
            }.padding(22)
            Divider()
            HSplitView {
                sources.frame(minWidth: 240, idealWidth: 285, maxWidth: 360)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        settings
                        if let plan = model.plan { preview(plan) }
                        let notices = model.warnings + (model.plan?.warnings ?? [])
                        if !notices.isEmpty {
                            DisclosureGroup("Замечания: \(notices.count)") {
                                Text(notices.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if !model.results.isEmpty { results }
                    }.padding(20)
                }.frame(minWidth: 500)
            }
            Divider()
            VStack(spacing: 10) {
                if model.busy { ProgressView(value: model.progress).accessibilityLabel("Прогресс подготовки") }
                HStack(spacing: 14) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.stage).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if model.busy {
                        Button("Остановить", role: .cancel) { model.cancel() }.keyboardShortcut(.cancelAction)
                    } else {
                        Button("Подготовить", systemImage: "list.bullet.clipboard") { model.prepare() }.disabled(model.selected.isEmpty)
                        Button("Экспортировать", systemImage: "film") { model.export() }
                            .buttonStyle(.borderedProminent).disabled(model.plan?.parts.isEmpty != false)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }.padding(18).background(.bar)
        }.frame(minWidth: 820, minHeight: 620)
            .toolbar {
                ToolbarItemGroup {
                    Button("Добавить", systemImage: "plus") { model.chooseSources() }.disabled(model.busy)
                    Button("Из Traktor", systemImage: "music.note.list") { model.fromTraktor() }.disabled(model.busy)
                    Button("Очистить", systemImage: "trash") { model.clear() }.disabled(model.busy || model.playlists.isEmpty)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy else { return false }; model.add(urls); return true
            } isTargeted: { targeted = $0 }
            .overlay { if targeted && !model.busy { RoundedRectangle(cornerRadius: 10).stroke(.tint, lineWidth: 3).padding(5).allowsHitTesting(false) } }
            .onChange(of: model.options) { _, _ in model.invalidate() }
            .sheet(isPresented: $model.showHelp) { help }
            .alert("Не удалось выполнить операцию", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Плейлисты").font(.headline)
                Spacer()
                Menu { Button("Выбрать все") { model.selectAll(true) }; Button("Снять выбор") { model.selectAll(false) } } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.busy).accessibilityLabel("Выбор плейлистов")
            }.padding(16)
            if model.playlists.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "square.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Перетащите плейлист\nили аудиофайлы").fontWeight(.medium).multilineTextAlignment(.center)
                    Text("Traktor NML · M3U/M3U8\nrekordbox XML · папки с музыкой")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Выбрать…") { model.chooseSources() }.disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.playlists) { playlist in
                        Toggle(isOn: Binding(get: { model.selected.contains(playlist.id) }, set: { model.toggle(playlist.id, $0) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).fontWeight(.medium).lineLimit(2)
                                Text("Треков: \(playlist.files.count + playlist.unavailable.count)" + (playlist.unavailable.isEmpty ? "" : " · недоступно: \(playlist.unavailable.count)")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 5).disabled(model.busy)
                    }
                }.listStyle(.sidebar)
            }
            Divider()
            Text("Выбрано треков: \(model.selectedCount)").font(.caption).foregroundStyle(.secondary).padding(16)
        }.background(.background)
    }
    private var settings: some View {
        GroupBox("Подготовка видео") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Один ролик на каждый плейлист", isOn: $model.options.separatePlaylists)
                Toggle("Треки целиком", isOn: Binding(get: { model.options.clipSeconds == nil }, set: { model.options.clipSeconds = $0 ? nil : 180 }))
                if model.options.clipSeconds != nil {
                    HStack {
                        Text("Фрагмент из середины")
                        Spacer()
                        TextField("Секунды", value: Binding(get: { model.options.clipSeconds ?? 180 }, set: { model.options.clipSeconds = $0 }), format: .number)
                            .frame(width: 75).textFieldStyle(.roundedBorder).accessibilityLabel("Длительность фрагмента в секундах")
                        Text("сек.").foregroundStyle(.secondary)
                    }
                    Text("Фрагмент проверяет только выбранную часть трека. Для полной проверки выберите треки целиком.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Звук", selection: $model.options.quality) {
                    Text("HQ · AAC 384 кбит/с · 48 кГц").tag(AudioQuality.high)
                    Text("AAC 192 кбит/с · 44,1 кГц").tag(AudioQuality.standard)
                }
                Picker("Максимум на видео", selection: $model.options.maxDuration) {
                    Text("До 15 минут").tag(895.0)
                    Text("1 час").tag(3600.0)
                    Text("6 часов").tag(21600.0)
                    Text("11 часов 54 минуты").tag(42840.0)
                }
                Text("Для загрузки видео длиннее 15 минут нужен подтверждённый аккаунт YouTube. Длинные подборки и треклисты делятся на части автоматически.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("Удалять дубли по исполнителю, названию и длительности", isOn: $model.options.deduplicateByMetadata)
                Toggle("Пропускать недоступные или повреждённые треки", isOn: $model.options.skipUnavailable)
                HStack {
                    Label(model.options.cover?.lastPathComponent ?? "Тёмная картинка · 640 × 360", systemImage: "photo").lineLimit(1)
                    Spacer()
                    Button("Картинка…") { model.chooseCover() }
                    if model.options.cover != nil { Button("Убрать") { model.options.cover = nil } }
                }
                Divider()
                HStack {
                    Label(model.output.path, systemImage: "folder").font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Изменить…") { model.chooseOutput() }
                }
            }.padding(10)
        }.disabled(model.busy)
    }
    private func preview(_ plan: ExportPlan) -> some View {
        GroupBox("План экспорта · \(plan.parts.count) видео") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.parts) { part in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(part.title).fontWeight(.medium)
                        Text("\(part.tracks.count) фрагментов · \(AppModel.duration(part.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private var results: some View {
        GroupBox("Готовые файлы") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(model.results.enumerated()), id: \.offset) { _, result in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                        Text(result.directory.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button("Треклист") { model.copyTracklist(result) }.help("Скопировать треклист")
                        Button("Finder") { model.reveal(result.directory) }
                    }
                }
                Link("Открыть YouTube Studio", destination: URL(string: "https://studio.youtube.com/")!)
                Text("Загрузите MP4 с доступом «Ограниченный доступ» и дождитесь шага «Проверки».")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Как проверить плейлист на YouTube").font(.title2.bold())
            Text("1. Добавьте NML, M3U/M3U8, XML rekordbox или папку с аудио. Выберите нужные плейлисты.")
            Text("2. Выберите фрагменты или полные треки, качество звука и место сохранения. Нажмите «Подготовить» и проверьте замечания.")
            Text("3. Нажмите «Экспортировать». Каждая часть получит MP4, треклист с таймкодами и текст для описания.")
            Text("4. В YouTube Studio загрузите MP4, вставьте описание из description.txt и установите «Ограниченный доступ».")
            Text("5. Дождитесь раздела «Проверки». Время совпадения сопоставьте с треклистом. Позже проверьте столбец «Ограничения».")
            Text("Setcheck подготавливает файлы. Проверку выполняет YouTube; отсутствие совпадений не гарантирует отсутствие будущих претензий или разрешение на использование музыки.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Правила загрузки и проверки YouTube", destination: URL(string: "https://support.google.com/youtube/answer/57407?hl=ru")!)
            HStack { Spacer(); Button("Понятно") { model.showHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 600)
    }
}
