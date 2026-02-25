import CloudKit
import Foundation

public enum RecordConverter {

    // MARK: - Workspace -> CKRecord

    public static func workspaceToCKRecord(
        workspace: Workspace,
        sortOrder: Int,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = CKRecord.ID(recordName: workspace.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: CKRecordTypes.workspace, recordID: recordID)

        record[CKWorkspaceFields.name] = workspace.name as CKRecordValue
        record[CKWorkspaceFields.sortOrder] = sortOrder as CKRecordValue

        // Encode colorId as its Codable string representation
        if let colorData = try? JSONEncoder().encode(workspace.colorId),
           let colorString = String(data: colorData, encoding: .utf8) {
            // Remove surrounding quotes from JSON string encoding
            let trimmed = colorString.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            record[CKWorkspaceFields.colorId] = trimmed as CKRecordValue
        }

        // Encode pinnedLinks as JSON string
        if let pinnedData = try? JSONEncoder().encode(workspace.pinnedLinks),
           let pinnedString = String(data: pinnedData, encoding: .utf8) {
            record[CKWorkspaceFields.pinnedLinksJSON] = pinnedString as CKRecordValue
        }

        // Encode browserProfiles as JSON string
        if let profilesData = try? JSONEncoder().encode(workspace.browserProfiles),
           let profilesString = String(data: profilesData, encoding: .utf8) {
            record[CKWorkspaceFields.browserProfilesJSON] = profilesString as CKRecordValue
        }

        return record
    }

    // MARK: - CKRecord -> Workspace

    /// Converts a CKRecord to a Workspace. The returned workspace has empty items;
    /// items are reconstructed separately from Node records.
    public static func ckRecordToWorkspace(record: CKRecord) -> Workspace? {
        guard record.recordType == CKRecordTypes.workspace else { return nil }
        guard let id = UUID(uuidString: record.recordID.recordName) else { return nil }
        guard let name = record[CKWorkspaceFields.name] as? String else { return nil }

        // Decode colorId
        var colorId: WorkspaceColorId = .defaultColor()
        if let colorString = record[CKWorkspaceFields.colorId] as? String {
            let jsonString = "\"\(colorString)\""
            if let colorData = jsonString.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(WorkspaceColorId.self, from: colorData) {
                colorId = decoded
            }
        }

        // Decode pinnedLinks
        var pinnedLinks: [Link] = []
        if let pinnedString = record[CKWorkspaceFields.pinnedLinksJSON] as? String,
           let pinnedData = pinnedString.data(using: .utf8) {
            pinnedLinks = (try? JSONDecoder().decode([Link].self, from: pinnedData)) ?? []
        }

        // Decode browserProfiles
        var browserProfiles: [String: String] = [:]
        if let profilesString = record[CKWorkspaceFields.browserProfilesJSON] as? String,
           let profilesData = profilesString.data(using: .utf8) {
            browserProfiles = (try? JSONDecoder().decode([String: String].self, from: profilesData)) ?? [:]
        }

        return Workspace(
            id: id,
            name: name,
            colorId: colorId,
            items: [],
            pinnedLinks: pinnedLinks,
            browserProfiles: browserProfiles
        )
    }

    // MARK: - Node Tree -> Flat CKRecords

    /// Flattens a node tree into an array of (CKRecord, Node) tuples with parent references and sort orders.
    public static func flattenNodes(
        nodes: [Node],
        workspaceId: UUID,
        zoneID: CKRecordZone.ID
    ) -> [(CKRecord, Node)] {
        var results: [(CKRecord, Node)] = []
        flattenNodesRecursive(
            nodes: nodes,
            workspaceId: workspaceId,
            parentNodeId: nil,
            zoneID: zoneID,
            results: &results
        )
        return results
    }

    private static func flattenNodesRecursive(
        nodes: [Node],
        workspaceId: UUID,
        parentNodeId: UUID?,
        zoneID: CKRecordZone.ID,
        results: inout [(CKRecord, Node)]
    ) {
        for (index, node) in nodes.enumerated() {
            let record = nodeToCKRecord(
                node: node,
                workspaceId: workspaceId,
                parentNodeId: parentNodeId,
                sortOrder: index,
                zoneID: zoneID
            )
            results.append((record, node))

            if case .folder(let folder) = node {
                flattenNodesRecursive(
                    nodes: folder.children,
                    workspaceId: workspaceId,
                    parentNodeId: folder.id,
                    zoneID: zoneID,
                    results: &results
                )
            }
        }
    }

    // MARK: - Node -> CKRecord

    public static func nodeToCKRecord(
        node: Node,
        workspaceId: UUID,
        parentNodeId: UUID?,
        sortOrder: Int,
        zoneID: CKRecordZone.ID
    ) -> CKRecord {
        let recordID = CKRecord.ID(recordName: node.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: CKRecordTypes.node, recordID: recordID)

        // Set type string
        let typeString: String
        switch node {
        case .folder: typeString = "folder"
        case .link: typeString = "link"
        case .task: typeString = "task"
        case .snippet: typeString = "snippet"
        }
        record[CKNodeFields.type] = typeString as CKRecordValue

        // Encode the associated value as JSON
        let encoder = JSONEncoder()
        let dataJSON: String?
        switch node {
        case .folder(let folder):
            // Encode folder metadata without children (children are separate records)
            let metadata = FolderMetadata(id: folder.id, name: folder.name, isExpanded: folder.isExpanded)
            dataJSON = (try? encoder.encode(metadata)).flatMap { String(data: $0, encoding: .utf8) }
        case .link(let link):
            dataJSON = (try? encoder.encode(link)).flatMap { String(data: $0, encoding: .utf8) }
        case .task(let task):
            dataJSON = (try? encoder.encode(task)).flatMap { String(data: $0, encoding: .utf8) }
        case .snippet(let snippet):
            dataJSON = (try? encoder.encode(snippet)).flatMap { String(data: $0, encoding: .utf8) }
        }

        if let json = dataJSON {
            record[CKNodeFields.dataJSON] = json as CKRecordValue
        }

        // Workspace reference
        let workspaceRecordID = CKRecord.ID(recordName: workspaceId.uuidString, zoneID: zoneID)
        record[CKNodeFields.workspaceRef] = CKRecord.Reference(
            recordID: workspaceRecordID,
            action: .deleteSelf
        ) as CKRecordValue

        // Parent node reference (nil for top-level nodes)
        if let parentId = parentNodeId {
            let parentRecordID = CKRecord.ID(recordName: parentId.uuidString, zoneID: zoneID)
            record[CKNodeFields.parentNodeRef] = CKRecord.Reference(
                recordID: parentRecordID,
                action: .none
            ) as CKRecordValue
        }

        record[CKNodeFields.sortOrder] = sortOrder as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> Node

    public static func ckRecordToNode(record: CKRecord) -> Node? {
        guard record.recordType == CKRecordTypes.node else { return nil }
        guard let typeString = record[CKNodeFields.type] as? String else { return nil }
        guard let dataJSON = record[CKNodeFields.dataJSON] as? String,
              let data = dataJSON.data(using: .utf8) else { return nil }

        let decoder = JSONDecoder()

        switch typeString {
        case "folder":
            guard let metadata = try? decoder.decode(FolderMetadata.self, from: data) else { return nil }
            let folder = Folder(id: metadata.id, name: metadata.name, children: [], isExpanded: metadata.isExpanded)
            return .folder(folder)
        case "link":
            guard let link = try? decoder.decode(Link.self, from: data) else { return nil }
            return .link(link)
        case "task":
            guard let task = try? decoder.decode(TaskItem.self, from: data) else { return nil }
            return .task(task)
        case "snippet":
            guard let snippet = try? decoder.decode(Snippet.self, from: data) else { return nil }
            return .snippet(snippet)
        default:
            return nil
        }
    }

    // MARK: - Flat Records -> Node Tree

    /// Reconstructs a node tree from flat node records using parent references.
    /// Returns top-level nodes (those with no parent reference) with children populated.
    public static func buildNodeTree(flatNodes: [(record: CKRecord, node: Node)]) -> [Node] {
        // Build lookup structures
        var nodeById: [UUID: Node] = [:]
        var parentIdMap: [UUID: UUID] = [:] // child ID -> parent ID
        var sortOrderMap: [UUID: Int] = [:]

        for (record, node) in flatNodes {
            nodeById[node.id] = node

            if let parentRef = record[CKNodeFields.parentNodeRef] as? CKRecord.Reference,
               let parentUUID = UUID(uuidString: parentRef.recordID.recordName) {
                parentIdMap[node.id] = parentUUID
            }

            if let sortOrder = record[CKNodeFields.sortOrder] as? Int {
                sortOrderMap[node.id] = sortOrder
            }
        }

        // Collect children for each parent
        var childrenMap: [UUID: [Node]] = [:]
        var topLevelNodes: [Node] = []

        for (_, node) in flatNodes {
            if let parentId = parentIdMap[node.id] {
                childrenMap[parentId, default: []].append(node)
            } else {
                topLevelNodes.append(node)
            }
        }

        // Sort children by sort order
        for (parentId, children) in childrenMap {
            childrenMap[parentId] = children.sorted {
                (sortOrderMap[$0.id] ?? 0) < (sortOrderMap[$1.id] ?? 0)
            }
        }

        topLevelNodes.sort {
            (sortOrderMap[$0.id] ?? 0) < (sortOrderMap[$1.id] ?? 0)
        }

        // Recursively build tree
        func buildChildren(for parentId: UUID) -> [Node] {
            guard let children = childrenMap[parentId] else { return [] }
            return children.map { node in
                if case .folder(let folder) = node {
                    let populatedChildren = buildChildren(for: folder.id)
                    return .folder(Folder(
                        id: folder.id,
                        name: folder.name,
                        children: populatedChildren,
                        isExpanded: folder.isExpanded
                    ))
                }
                return node
            }
        }

        return topLevelNodes.map { node in
            if case .folder(let folder) = node {
                let populatedChildren = buildChildren(for: folder.id)
                return .folder(Folder(
                    id: folder.id,
                    name: folder.name,
                    children: populatedChildren,
                    isExpanded: folder.isExpanded
                ))
            }
            return node
        }
    }
}

// MARK: - Internal Helpers

/// Lightweight struct for encoding folder metadata without children.
/// Children are stored as separate Node records with parent references.
private struct FolderMetadata: Codable {
    let id: UUID
    let name: String
    let isExpanded: Bool
}
