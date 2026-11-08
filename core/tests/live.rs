use haneoka_core::game::{client_version, Region};

#[tokio::test]
#[ignore = "contacts the game servers"]
async fn discovers_client_versions() {
    for region in [Region::Jp, Region::En] {
        let version = client_version(region, None).await;
        println!("{region:?}: {version:?}");
        assert!(version.is_ok());
    }
}
