import CloudKit

public enum CKRecordTypes {
    public static let workspace = "Workspace"
    public static let node = "Node"
    public static let faviconAsset = "FaviconAsset"
}

public enum CKWorkspaceFields {
    public static let name = "name"
    public static let colorId = "colorId"
    public static let sortOrder = "sortOrder"
    public static let browserProfilesJSON = "browserProfilesJSON"
}

public enum CKNodeFields {
    public static let type = "type"
    public static let dataJSON = "dataJSON"
    public static let workspaceRef = "workspaceRef"
    public static let parentNodeRef = "parentNodeRef"
    public static let sortOrder = "sortOrder"
}

public enum CKFaviconFields {
    public static let host = "host"
    public static let imageData = "imageData"
}
