import Testing
@testable import SQL2SQLiteKit

private func translate(_ sql: String) throws -> TranslatedView {
    try ViewTranslator.translate(
        Statement(bytes: Array(sql.utf8), byteOffset: 0, line: 1), diagnostics: .discarding())
}

@Test func stripsAlgorithmDefinerAndSecurityClauses() throws {
    let v = try translate("""
    CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER \
    VIEW `active_users` AS select `u`.`id` AS `id` from `users` `u` where (`u`.`active` = 1)
    """)
    #expect(v.name == "active_users")
    #expect(v.createSQL == """
    CREATE VIEW "active_users" AS select "u"."id" AS "id" from "users" "u" where ("u"."active" = 1)
    """)
}

@Test func keepsAnExplicitColumnList() throws {
    let v = try translate("CREATE VIEW `v` (`a`,`b`) AS select 1,2")
    #expect(v.createSQL == #"CREATE VIEW "v" ("a", "b") AS select 1,2"#)
}

@Test func stripsWithCheckOption() throws {
    let v = try translate("CREATE VIEW `v` AS select 1 WITH CASCADED CHECK OPTION")
    #expect(v.createSQL == #"CREATE VIEW "v" AS select 1"#)
}

@Test func requotesMySQLStringsInTheBody() throws {
    let v = try translate(#"CREATE VIEW `v` AS select "lit" AS `x`"#)
    #expect(v.createSQL == #"CREATE VIEW "v" AS select 'lit' AS "x""#)
}

@Test func throwsOnANonViewStatement() {
    #expect(throws: ConversionError.self) { _ = try translate("CREATE TABLE t (a int)") }
}
