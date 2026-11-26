import SwiftUI

struct ModelMediaSummary: View {
    let capabilities: ModelMediaCapabilities

    var body: some View {
        let supported = ModelMediaFeature.allCases.filter { capabilities[$0] == true }
        if !supported.isEmpty {
            Text(verbatim: supported.map(\.title).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ModelMediaDetailSection: View {
    let capabilities: ModelMediaCapabilities

    private func statusText(for feature: ModelMediaFeature) -> String {
        switch capabilities[feature] {
        case true?: return String(localized: "支持")
        case false?: return String(localized: "不支持")
        case nil: return String(localized: "未提供")
        }
    }

    var body: some View {
        Section {
            if capabilities.hasInformation {
                ForEach(ModelMediaFeature.allCases, id: \.rawValue) { feature in
                    let status = statusText(for: feature)
                    LabeledContent(feature.title, value: status)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(feature.title)
                        .accessibilityValue(status)
                        .accessibilityIdentifier("model.media.\(feature.rawValue)")
                }
            } else {
                Text("暂无此模型的输入输出能力资料。").foregroundStyle(.secondary)
            }
        } header: {
            Text("模型原生能力")
        } footer: {
            Text("根据服务商目录或官方模型资料显示。输入指模型可接收的内容，输出指模型可直接生成的内容。系统听写和朗读属于设备功能。")
        }
    }
}
