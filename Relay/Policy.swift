//
//  Policy.swift
//  Relay
//
//  Slice 3 — gate 3 of the security spine (SPEC §3). A *pure*, deterministic screen
//  over forwarded input: catastrophic shapes are refused outright (`.denied`), risky
//  but recoverable shapes require a `/confirm` (`.flagged`), everything else passes
//  (`.clean`). No I/O — trivially unit-tested. Default preset ships strict.
//

import Foundation

/// The verdict for a single line of input. `denied` always wins over `flagged`.
nonisolated enum PolicyVerdict: Equatable, Sendable {
    case clean
    case flagged
    case denied
}

/// A pair of case-insensitive regex pattern lists: `denylist` (refuse) and `flagged`
/// (require confirmation). `Sendable`/`Equatable` by storing the pattern *sources*
/// (compiled at match time), so a `Policy` is a value that's safe to share across
/// actors and cheap to compare in tests.
nonisolated struct Policy: Equatable, Sendable {
    /// Patterns whose match refuses the input outright (catastrophic shapes).
    var denylist: [String]
    /// Patterns whose match holds the input pending a `/confirm` (recoverable risk).
    var flagged: [String]

    /// Classify `text`. Denylist is checked first so it takes precedence over `flagged`.
    func screen(_ text: String) -> PolicyVerdict {
        if Self.matchesAny(text, denylist) { return .denied }
        if Self.matchesAny(text, flagged) { return .flagged }
        return .clean
    }

    private static func matchesAny(_ text: String, _ patterns: [String]) -> Bool {
        for pattern in patterns
        where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }
}

nonisolated extension Policy {
    /// Catastrophic shapes — always refused, in every preset (SPEC §3). Narrow on
    /// purpose: each pattern targets the irreversible form, not its benign cousins
    /// (e.g. raw-disk writes match but `of=/dev/null` does not).
    private static let catastrophic = [
        #"\brm\s+-[a-z]*[rf][a-z]*\s+(/|~)(\*|\s|$)"#,                  // recursive delete of / or ~
        #"\bof=/dev/r?disk"#,                                          // dd onto a raw disk device
        #">\s*/dev/r?disk"#,                                           // redirect onto a raw disk device
        #":\(\)\s*\{"#,                                                // classic fork bomb
        #"\b(curl|wget|fetch)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|dash|ksh)\b"#, // pipe download → shell
        #"/\.ssh/id_[a-z]"#,                                           // read a private SSH key
        #"/\.aws/credentials\b"#,                                      // read AWS credentials
        #"\bsecurity\s+dump-keychain\b"#,                              // dump the macOS keychain
    ]

    /// Default — refuses catastrophes and holds a broad set of risky verbs for `/confirm`.
    static let strict = Policy(
        denylist: catastrophic,
        flagged: [
            #"\bsudo\b"#,
            #"\brm\s+-[a-z]*[rf][a-z]*\b"#,        // any recursive/force rm (root/home already denied)
            #"\bgit\s+push\b.*--force\b"#,
            #"\bgit\s+reset\s+--hard\b"#,
            #"\b(shutdown|reboot|halt)\b"#,
            #"\bkillall\b"#,
            #"\bkill\s+-9\b"#,
            #"\bchmod\s+-R\b"#,
            #"\bchown\s+-R\b"#,
        ]
    )

    /// Lighter — same catastrophic floor, but only privilege escalation and recursive
    /// deletes are held for confirmation.
    static let standard = Policy(
        denylist: catastrophic,
        flagged: [
            #"\bsudo\b"#,
            #"\brm\s+-[a-z]*[rf][a-z]*\b"#,
        ]
    )

    /// Map the persisted selector (`BotConfig.policyPreset`) to a concrete policy.
    static func preset(_ preset: PolicyPreset) -> Policy {
        switch preset {
        case .strict: return .strict
        case .standard: return .standard
        }
    }
}
