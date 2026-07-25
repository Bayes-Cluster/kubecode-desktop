import KubecodeUI

enum ExplorerFilterPresentation {
    static func hiddenFilesSymbol(showHidden: Bool) -> String {
        showHidden ? "eye" : "eye.slash"
    }
}

struct ExplorerSectionState: Equatable {
    var changesExpanded = true
    var planExpanded = true
    var filesExpanded = true
    private var planRevision: [AgentPlanEntry]?

    mutating func synchronize(plan: [AgentPlanEntry]) {
        guard !plan.isEmpty else {
            planRevision = nil
            return
        }
        if planRevision != plan { planExpanded = true }
        planRevision = plan
    }
}
