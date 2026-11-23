import MCP
import RePossessLibrary
import RePossessRecognize

/// The output schemas of the tools whose results have `structuredContent`.
///
/// Each schema describes the JSON that a result type in ``RePossessTools`` encodes.
/// A property that the type makes optional is absent, not `null`, when it has no value,
/// so it is not in `required`.
extension RePossessTools {
    /// A closed object schema with these properties.
    static func objectSchema(
        _ properties: [String: Value],
        required: [String],
        description: String? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    static func enumProperty(_ values: [String], _ description: String) -> Value {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    static func dateProperty(_ description: String) -> Value {
        ["type": "string", "description": .string(description + " An ISO 8601 date and time in UTC.")]
    }

    static let sourceProperty = enumProperty(
        Source.allCases.map(\.rawValue),
        "Where the mirror's copy of the document came from."
    )
    static let contentStatusProperty = enumProperty(
        ContentStatus.allCases.map(\.rawValue),
        """
        What to look at to read the document: text when every page has text or nothing to read, \
        partial when some pages have text and some do not, ink for handwriting or drawings without text, \
        annotated for a PDF or EPUB with handwriting or drawings, and image for pages without a text layer.
        """
    )
    static let fileTypeProperty: Value = [
        "type": "string",
        "description": "The document's file type from the tablet, such as notebook, pdf, or epub.",
    ]

    static let mirrorSchema = objectSchema(
        [
            "source": enumProperty(Source.allCases.map(\.rawValue), "Where the most recent refresh came from."),
            "refreshed": dateProperty("When the most recent refresh finished."),
            "age_seconds": ["type": "integer", "minimum": 0, "description": "The mirror's age, in seconds."],
            "age": ["type": "string", "description": "The mirror's age in words, such as \"3 hours\"."],
        ],
        required: ["source", "refreshed", "age_seconds", "age"],
        description: "Where the mirror came from and how old it is. Absent when the mirror was never refreshed."
    )

    // MARK: list_documents

    static let listOutputSchema = objectSchema(
        [
            "folders": [
                "type": "array",
                "items": objectSchema(
                    [
                        "id": ["type": "string"],
                        "name": ["type": "string"],
                        "kind": enumProperty(["CollectionType"], "Always CollectionType for a folder."),
                        "parent": [
                            "type": "string", "description": "The parent folder's ID, or empty for the top level.",
                        ],
                        "path": ["type": "string", "description": "The folders and the name, joined by /."],
                    ],
                    required: ["id", "name", "kind", "parent", "path"]
                ),
            ],
            "documents": [
                "type": "array",
                "items": objectSchema(
                    [
                        "id": ["type": "string"],
                        "name": ["type": "string"],
                        "kind": enumProperty(["DocumentType"], "Always DocumentType for a document."),
                        "parent": [
                            "type": "string", "description": "The parent folder's ID, or empty for the top level.",
                        ],
                        "path": ["type": "string", "description": "The folders and the name, joined by /."],
                        "modified": dateProperty(
                            "When the document last changed, or empty when the tablet gave no time."
                        ),
                        "file_type": fileTypeProperty,
                        "page_count": ["type": "integer", "minimum": 0],
                        "content_status": contentStatusProperty,
                        "summary": [
                            "type": "string",
                            "description": "The start of the document's text, or why the document could not be read.",
                        ],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "The document's tags."],
                        "page_tags": [
                            "type": "array",
                            "description": "The tags on the document's pages.",
                            "items": objectSchema(
                                [
                                    "page_no": [
                                        "type": "integer", "minimum": 1,
                                        "description": "The page number, starting at 1.",
                                    ],
                                    "tag": ["type": "string"],
                                ],
                                required: ["page_no", "tag"]
                            ),
                        ],
                        "source": sourceProperty,
                    ],
                    required: [
                        "id", "name", "kind", "parent", "path", "modified", "file_type", "page_count",
                        "content_status", "summary", "tags", "page_tags", "source",
                    ]
                ),
            ],
            "mirror": mirrorSchema,
        ],
        required: ["folders", "documents"]
    )

    // MARK: search_documents

    static let searchOutputSchema = objectSchema(
        [
            "query": ["type": "string", "description": "The words that were searched for."],
            "total": [
                "type": "integer", "minimum": 0,
                "description": "The number of matches, which can be more than the results that the limit allows.",
            ],
            "results": [
                "type": "array",
                "items": objectSchema(
                    [
                        "id": ["type": "string"],
                        "name": ["type": "string"],
                        "path": ["type": "string", "description": "The folders and the name, joined by /."],
                        "file_type": fileTypeProperty,
                        "content_status": contentStatusProperty,
                        "match": enumProperty(
                            SearchHit.Match.allCases.map(\.rawValue),
                            """
                            What matched: the name, a tag, typed or PDF text, \
                            or handwriting that the owner's recognizer read as text.
                            """
                        ),
                        "page_no": [
                            "type": "integer", "minimum": 1,
                            "description":
                                "The page of the match, starting at 1. Absent for a match on the name or a document tag.",
                        ],
                        "snippet": ["type": "string", "description": "The matching text, or the name or tag."],
                    ],
                    required: ["id", "name", "path", "file_type", "content_status", "match", "snippet"]
                ),
            ],
            "mirror": mirrorSchema,
        ],
        required: ["query", "total", "results"]
    )

    // MARK: push_markdown and push_file

    /// The `status` values of a ``PushResult``.
    static let pushStatuses = ["sent", "queued", "unknown", "failed"]

    static let pushOutputSchema = objectSchema(
        [
            "push_id": ["type": "string", "description": "The push's ID in rePossess's queue."],
            "title": ["type": "string", "description": "The document's name on the tablet."],
            "kind": enumProperty(PushKind.allCases.map(\.rawValue), "The kind of document that the push makes."),
            "status": enumProperty(
                pushStatuses,
                """
                sent: the tablet or reMarkable's cloud has it. queued or unknown: rePossess sends it, \
                or checks whether it arrived, at the next refresh; do not push it again. \
                failed: it was refused and added nothing.
                """
            ),
            "via": enumProperty(
                Source.allCases.map(\.rawValue),
                "The path of the last send. Absent when rePossess has not sent it yet."
            ),
            "tablet_id": [
                "type": "string",
                "description": "The document's ID on the tablet. Absent when rePossess does not know it.",
            ],
            "pages": [
                "type": "integer", "minimum": 0,
                "description": "The page count of a notebook made from Markdown. Absent for a PDF or EPUB.",
            ],
            "bytes": ["type": "integer", "minimum": 0, "description": "The size of the document's file, in bytes."],
            "message": ["type": "string", "description": "What happened, in a sentence or two."],
            "folder": [
                "type": "string",
                "description": "The top-level folder that the push goes into. Absent for the top level of the library.",
            ],
        ],
        required: ["push_id", "title", "kind", "status", "bytes", "message"]
    )

    // MARK: status

    static func transportSchema(_ available: String) -> Value {
        objectSchema(
            [
                "available": ["type": "boolean", "description": .string(available)],
                "last_success": dateProperty(
                    "When the last refresh from this source finished. Absent when none has finished."
                ),
                "last_error": [
                    "type": "string",
                    "description":
                        "Why the last refresh from this source failed. Absent unless it failed after the last success.",
                ],
                "last_error_at": dateProperty("When the last refresh from this source failed."),
            ],
            required: ["available"]
        )
    }

    /// The `state` values of the recognizer in `status`.
    static let recognizerStates = ["off", "ready", "unavailable"]

    static let statusOutputSchema = objectSchema(
        [
            "library": ["type": "string", "description": "The path of the library folder on this Mac."],
            "documents": ["type": "integer", "minimum": 0],
            "folders": ["type": "integer", "minimum": 0],
            "pages": ["type": "integer", "minimum": 0],
            "usb": transportSchema("Whether the tablet is on the Mac's USB network now."),
            "cloud": transportSchema("Whether rePossess is paired with reMarkable's cloud."),
            "mirror": mirrorSchema,
            "pushes": objectSchema(
                Dictionary(
                    uniqueKeysWithValues: pushStatuses.map { ($0, ["type": "integer", "minimum": 0] as Value) }
                ),
                required: [],
                description: "The number of pushes in each status. A status without pushes is absent."
            ),
            "recognizer": objectSchema(
                [
                    "state": enumProperty(
                        recognizerStates,
                        """
                        off: no recognizer is configured. ready: the recognizer can read pages. \
                        unavailable: it is configured but cannot read pages now; note says why.
                        """
                    ),
                    "provider": enumProperty(
                        RecognizerProvider.allCases.map(\.rawValue),
                        "The recognizer's provider. Absent when state is off or the configuration could not be read."
                    ),
                    "model": ["type": "string", "description": "The model that reads the pages."],
                    "label": ["type": "string", "description": "The name that recognized text is labeled with."],
                    "page_images_go_to": [
                        "type": "string", "description": "Where page images go to be recognized.",
                    ],
                    "pages_with_handwriting": ["type": "integer", "minimum": 0],
                    "pages_recognized": [
                        "type": "integer", "minimum": 0, "description": "Pages whose handwriting is read as text.",
                    ],
                    "pages_without_words": [
                        "type": "integer", "minimum": 0,
                        "description": "Pages that the recognizer read and found no words on.",
                    ],
                    "pages_refused": [
                        "type": "integer", "minimum": 0, "description": "Pages that the recognizer refused to read.",
                    ],
                    "pages_waiting": [
                        "type": "integer", "minimum": 0, "description": "Pages of handwriting not recognized yet.",
                    ],
                    "note": ["type": "string", "description": "What to call to read handwriting now."],
                ],
                required: ["state", "note"],
                description: "The handwriting recognizer that the owner configured."
            ),
        ],
        required: ["library", "documents", "folders", "pages", "usb", "cloud", "pushes", "recognizer"]
    )
}
