/// Namespace for facts about the app as a whole.
///
/// An `enum` with no cases can never be instantiated, which makes it the
/// idiomatic Swift way to group static constants.
public enum ScrobblerCore {
    /// Shown in the menu and sent nowhere; bump it when you tag a release.
    public static let version = "0.1.0"
}
