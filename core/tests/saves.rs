use haneoka_core::save::{GameRelease, SaveCandidate, SaveCollector};
use haneoka_core::{codec, export, game, store};

const CACHE: &[u8] = include_bytes!("fixtures/cache.bin");
const PERSIST: &[u8] = include_bytes!("fixtures/persist.bin");

fn candidate(name: &str, seconds: i64) -> SaveCandidate {
    SaveCandidate {
        source: format!("account/{name}"),
        modified_at: chrono::DateTime::from_timestamp(seconds, 0),
        release: Some(GameRelease::Jp),
        group: Some("account".into()),
    }
}

fn collected() -> haneoka_core::save::GameSave {
    let mut collector = SaveCollector::new();
    assert!(collector.offer(CACHE, &candidate("a", 100)));
    assert!(collector.offer(PERSIST, &candidate("b", 100)));
    assert!(!collector.offer(b"not a save", &candidate("c", 100)));
    let mut saves = collector.saves();
    assert_eq!(saves.len(), 1);
    saves.remove(0)
}

#[test]
fn decrypts_original_saves() {
    let cache = codec::decode(CACHE).expect("cache decodes");
    assert!(cache.contains_key("_player"));
    let persist = codec::decode(PERSIST).expect("persist decodes");
    assert_eq!(persist["_certification"]["_playerId"], "p-1");
    let mut tampered = CACHE.to_vec();
    let last = tampered.len() - 1;
    tampered[last] ^= 1;
    assert!(codec::decode(&tampered).is_none());
    assert!(codec::decode(b"\xEF\xBB\xBF{\"a\":1}").is_some());
}

#[test]
fn groups_documents_by_account() {
    let save = collected();
    assert_eq!(save.profile_id, "51234567890");
    assert_eq!(save.server(), Some("jp"));
    assert_eq!(save.key(), "jp-51234567890");
    assert_eq!(save.player_rank(), Some(42));
    assert!(game::session(&save).is_some());
    assert_eq!(game::Region::of(&save), Some(game::Region::Jp));
}

#[test]
fn exports_without_identity() {
    let save = collected();
    let snapshot = export::snapshot(&save);
    assert!(snapshot.contains("haneoka-game-save-v1"));
    assert!(!snapshot.contains("Tester") && !snapshot.contains("_password"));
    assert!(snapshot.contains("12345678901234567000"));
    let full = String::from_utf8(export::full(&save)).unwrap();
    assert!(!full.contains("secret") && !full.contains("_certification"));
    let marks = export::song_marks(&save);
    assert_eq!(marks["l.100001.0"], 3);
    assert_eq!(marks["l.100001.2"], 1);
    assert!(!marks.contains_key("l.100001.3"));
    assert!(export::team_package(&save).starts_with("ONPKG1:"));
}

#[test]
fn exported_saves_import_again() {
    let save = collected();
    let mut collector = SaveCollector::new();
    let document: serde_json::Value = serde_json::from_slice(&export::full(&save)).unwrap();
    assert!(collector.offer_json(document.as_object().unwrap().clone(), &candidate("export.json", 0)));
    let again = collector.saves().remove(0);
    assert_eq!(again.profile_id, save.profile_id);
    assert_eq!(again.rows("_memberCards").len(), 1);
}

#[test]
fn stores_and_merges_accounts() {
    let folder = tempfile::tempdir().unwrap();
    let accounts = store::AccountStore::new(folder.path());
    let save = collected();
    accounts.put(save.clone()).unwrap();
    let reopened = store::AccountStore::new(folder.path());
    let stored = reopened.find("jp-51234567890").expect("stored");
    assert_eq!(stored.documents.len(), 2);
    assert_eq!(stored.name.as_deref(), Some("Tester"));
    assert!(folder.path().join("jp-51234567890.json").is_file());
    reopened.remove("jp-51234567890").unwrap();
    assert!(reopened.saves().is_empty());
}

#[test]
fn reads_flutter_account_files() {
    let folder = tempfile::tempdir().unwrap();
    std::fs::write(
        folder.path().join("intl-31234567890.json"),
        r#"{"schema":"haneoka-account-v1","profileId":"31234567890","name":null,"release":"intlStore","source":"x",
            "documents":{"cache":{"modifiedAt":"2026-10-01T10:00:00.000Z","data":{"_player":{"_profileId":31234567890}}}}}"#,
    )
    .unwrap();
    let accounts = store::AccountStore::new(folder.path());
    let saves = accounts.saves();
    assert_eq!(saves.len(), 1);
    assert_eq!(saves[0].release, Some(GameRelease::IntlStore));
    assert_eq!(saves[0].key(), "intl-31234567890");
    assert_eq!(saves[0].region(), Some("en"));
}

fn varint(mut v: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn field_varint(number: u64, value: u64, out: &mut Vec<u8>) {
    varint(number << 3, out);
    varint(value, out);
}

fn field_bytes(number: u64, bytes: &[u8], out: &mut Vec<u8>) {
    varint(number << 3 | 2, out);
    varint(bytes.len() as u64, out);
    out.extend_from_slice(bytes);
}

#[test]
fn decodes_history_responses() {
    let mut prize = Vec::new();
    field_varint(1, 9001, &mut prize);
    field_varint(2, 1, &mut prize);
    let mut execution = Vec::new();
    field_varint(1, 55, &mut execution);
    field_varint(3, 250, &mut execution);
    field_varint(6, 1_760_000_000, &mut execution);
    field_bytes(7, &prize, &mut execution);
    let mut response = Vec::new();
    field_bytes(2, &execution, &mut response);
    let snapshot = game::decode_history(&response, "jp", "1.2.3", None).unwrap();
    assert_eq!(snapshot["historyKind"], "execution");
    assert_eq!(snapshot["batches"][0]["poolId"], "55");
    assert_eq!(snapshot["batches"][0]["freeGems"], 250);
    assert_eq!(snapshot["batches"][0]["prizes"][0]["prizeId"], "9001");
    assert_eq!(snapshot["batches"][0]["prizes"][0]["converted"], true);
    assert!(game::decode_history(&[0xff], "jp", "1", None).is_err());
}

#[test]
fn decodes_player_data() {
    let mut card = Vec::new();
    field_varint(2, 7, &mut card);
    field_varint(3, 1000, &mut card);
    let mut player = Vec::new();
    field_bytes(2, &card, &mut player);
    let mut response = Vec::new();
    field_bytes(1, &player, &mut response);
    let data = game::decode_player_data(&response).unwrap();
    assert_eq!(data["_memberCards"][0]["_masterId"], 7);
    assert_eq!(data["_memberCards"][0]["_exp"], 1000);
    assert_eq!(data["_supportCards"].as_array().unwrap().len(), 0);
}
