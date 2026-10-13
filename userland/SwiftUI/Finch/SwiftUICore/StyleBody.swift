// SPDX-License-Identifier: MIT OR Apache-2.0
//
// A style's body made in the view graph, as Apple's styles' are: the style is the body's
// container, so its own dynamic properties (@Environment, @State, ...) are installed and read
// the view's environment, as a view's are. Finch's style hosts (button, group box, form and
// primitive button styles) make their styles' bodies through it.

import OpenAttributeGraphShims

package struct _FinchStyleView<Style, Configuration, StyleBody>: View, PrimitiveView where StyleBody: View {
    package var style: Style
    package var configuration: Configuration
    package var makeStyleBody: (Style, Configuration) -> StyleBody

    package init(style: Style, configuration: Configuration, body: @escaping (Style, Configuration) -> StyleBody) {
        self.style = style
        self.configuration = configuration
        makeStyleBody = body
    }

    private struct Accessor: BodyAccessor {
        @Attribute var view: _FinchStyleView

        typealias Container = Style
        typealias Body = StyleBody

        func updateBody(of container: Style, changed: Bool) {
            let (view, viewChanged) = $view.changedValue()
            guard changed || viewChanged else { return }
            setBody { view.makeStyleBody(container, view.configuration) }
        }
    }

    private static func makeBody(view: _GraphValue<Self>, inputs: inout _GraphInputs)
        -> (_GraphValue<StyleBody>, _DynamicPropertyBuffer?, DynamicPropertyCache.Fields) {
        let fields = DynamicPropertyCache.fields(of: Style.self)
        let (body, buffer) = Accessor(view: view.value)
            .makeBody(container: view[offset: { .of(&$0.style) }], inputs: &inputs, fields: fields)
        return (body, buffer, fields)
    }

    nonisolated package static func _makeView(view: _GraphValue<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        var inputs = inputs
        let (body, buffer, fields) = makeBody(view: view, inputs: &inputs.base)
        let outputs = StyleBody.makeDebuggableView(view: body, inputs: inputs)
        buffer?.traceMountedProperties(to: view, fields: fields)
        return outputs
    }

    nonisolated package static func _makeViewList(view: _GraphValue<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        var inputs = inputs
        let (body, buffer, fields) = makeBody(view: view, inputs: &inputs.base)
        let outputs = StyleBody.makeDebuggableViewList(view: body, inputs: inputs)
        buffer?.traceMountedProperties(to: view, fields: fields)
        return outputs
    }

    nonisolated package static func _viewListCount(inputs: _ViewListCountInputs) -> Int? {
        StyleBody._viewListCount(inputs: inputs)
    }

    package typealias Body = Never
}
