import SwiftData
import SwiftUI

struct RegionImageEditor: View {
    let message: ChatMessage
    let attachmentID: UUID
    @Query private var providers: [ProviderConfig]
    @Environment(\.modelContext) private var context
    @State private var selected: UUID?
    @State private var choice = ""
    @State private var instruction = ""
    @State private var selection = CGRect.zero
    @State private var split = 0.5
    @State private var compare = false
    @State private var task: Task<Void, Never>?
    @State private var issue = ""
    @State private var share: ExportSharePayload?
    @State private var consent = AIConsentGate()
    private var item: MessageAttachment? { message.attachments.first { $0.id == attachmentID } }
    private var versions: [EditedImage] { item?.editedVersions ?? [] }
    private var version: EditedImage? { versions.first { $0.id == selected } }
    private func picture(_ id: UUID?) -> UIImage? {
        if let id, let data = versions.first(where: { $0.id == id })?.png { return UIImage(data: data) }
        guard let raw = item?.dataBase64, let data = Data(base64Encoded: raw) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Form {
            Section {
                Picker("版本", selection: $selected) {
                    Text("原图").tag(nil as UUID?)
                    ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                        Text("\(i+1) · \(v.instruction)").tag(Optional(v.id))
                    }
                }.disabled(task != nil)
                if selected != nil { Toggle("与编辑前对照", isOn: $compare) }
                if let image = picture(selected) {
                    GeometryReader { geo in
                        let size = geo.size
                        ZStack(alignment: .leading) {
                            Image(uiImage: image).resizable()
                            if compare && selected != nil, let parent = picture(version?.parent) {
                                Image(uiImage: parent).resizable().mask(alignment: .leading) {
                                    Rectangle().frame(width: size.width * split)
                                }
                                Rectangle().fill(.white).frame(width: 2).offset(x: size.width * split)
                            } else {
                                Rectangle().stroke(.yellow, lineWidth: 2)
                                    .frame(width: size.width * selection.width, height: size.height * selection.height)
                                    .position(x: size.width * selection.midX, y: size.height * selection.midY)
                            }
                        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                            guard task == nil else { return }
                            if compare && selected != nil { split = min(1,max(0,drag.location.x / size.width)); return }
                            let a = drag.startLocation, b = drag.location
                            let rect = CGRect(x: min(a.x,b.x)/size.width, y: min(a.y,b.y)/size.height,
                                              width: abs(a.x-b.x)/size.width, height: abs(a.y-b.y)/size.height)
                            selection = rect.intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
                        })
                    }.aspectRatio(image.size, contentMode: .fit)
                }
                Button("导出当前版本") {
                    do {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fugue-" + UUID().uuidString + ".png")
                        guard let image = picture(selected), let data = image.pngData() else { throw LLMError.emptyResponse }
                        try data.write(to: url, options: [.atomic, .completeFileProtection])
                        share = ExportSharePayload(url: url)
                    } catch { issue = error.localizedDescription }
                }
                Text(compare && selected != nil ? "滑动分隔线对照两个版本" : "在图上拖出需要修改的矩形").font(.footnote)
            }
            let eligible = providers.filter { $0.protocolType == .gemini }
            TaskModelPicker(providers: eligible, choice: $choice, title: "图片编辑模型")
            TextField("描述选区内的修改", text: $instruction)
            if let model = TaskModel.options(eligible).first(where: { $0.id == choice }) {
                Button("发送选区给 \(model.recipient)") {
                    consent.perform(recipients: [model.recipient]) {
                        task = Task {
                            defer { task = nil }
                            do { try await edit(model); issue = "" } catch { issue = error.localizedDescription }
                        }
                    }
                }.disabled(task != nil || compare || selection.width < 0.01 || selection.height < 0.01 || instruction.isEmpty)
            } else { Text("请选择支持图片输出的 Gemini 模型。") }
            if task != nil { Button("取消") { task?.cancel() } }
            if !issue.isEmpty { Text(issue).foregroundStyle(.red) }
        }.navigationTitle("选区改图与版本对照").aiConsentSheet(consent)
        .onChange(of: selected) { selection = .zero; if selected == nil { compare = false } }
        .sheet(item: $share) { payload in ReplyActivityShareSheet(items: [payload.url]) }
        .onDisappear { task?.cancel() }
    }

    static func replacingRegion(in base: UIImage, size: CGSize, rect: CGRect, with edit: UIImage) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
            edit.draw(in: rect)
        }
    }

    private func edit(_ model: TaskModel) async throws {
        guard let base = picture(selected), let cg = base.cgImage,
              max(cg.width,cg.height) <= 4096, versions.count < 12 else { throw ModelTaskError.invalid("支持最长边 4096 像素、最多 12 个版本") }
        let size = CGSize(width: base.size.width * base.scale, height: base.size.height * base.scale)
        let rect = CGRect(x: selection.minX*size.width, y: selection.minY*size.height, width: selection.width*size.width, height: selection.height*size.height).integral.intersection(CGRect(origin: .zero, size: size))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let region = UIGraphicsImageRenderer(size: rect.size, format: format).pngData { _ in
            base.draw(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: size))
        }
        let prompt = instruction, parent = selected
        let input = MessageAttachment(kind: .image, fileName: "region.png", mimeType: "image/png", dataBase64: region.base64EncodedString(), extractedText: nil, byteSize: region.count)
        let out = try await model.run("", input: prompt, attachments: [input], image: true, limit: 8192)
        guard let encoded = out.images.first?.dataBase64, let bytes = Data(base64Encoded: encoded),
              let edit = UIImage(data: bytes) else { throw ModelTaskError.invalid("模型未返回编辑后的图片") }
        let png = Self.replacingRegion(in: base, size: size, rect: rect, with: edit)
        try Task.checkCancellation()
        guard !message.isDeleted, let i = message.attachments.firstIndex(where: { $0.id == attachmentID }) else { throw LLMError.unavailableModel }
        var all = message.attachments
        let old = all
        var history = all[i].editedVersions ?? []
        guard history.count < 12, history.reduce(png.count, { $0 + $1.png.count }) <= 32*1024*1024 else { throw ModelTaskError.invalid("图片版本已达到存储上限") }
        let result = EditedImage(parent: parent, instruction: prompt, png: png)
        let previousDate = message.conversation?.updatedAt
        history.append(result); all[i].editedVersions = history; message.attachments = all
        message.conversation?.updatedAt = Date()
        do { try context.save() } catch {
            message.attachments = old
            if let previousDate { message.conversation?.updatedAt = previousDate }
            throw error
        }
        selected = result.id; compare = true
    }
}
