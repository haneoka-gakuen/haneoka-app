//! Durable download queue and batch operations shared by website actions and the local library.
use super::*;
use crate::AppState;
use tauri::AppHandle;

#[derive(Clone, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase")]
struct Target {
    server: String,
    chapter: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    episode: Option<String>,
}

impl Target {
    fn valid(&self) -> bool {
        let id = |value: &str| {
            !value.is_empty()
                && value.len() <= 240
                && !value
                    .chars()
                    .any(|c| c.is_control() || matches!(c, '/' | '\\'))
        };
        if let Some(source) = Source::parse(&self.server) {
            return source.valid_id(&self.chapter)
                && self
                    .episode
                    .as_ref()
                    .is_none_or(|episode| episode == &self.chapter);
        }
        matches!(self.server.as_str(), "jp" | "intl")
            && id(&self.chapter)
            && self.episode.as_deref().is_none_or(id)
    }

    fn normalized(mut self) -> Self {
        if Source::parse(&self.server).is_some() {
            self.episode = None;
        }
        self
    }

    fn parent_key(&self) -> String {
        format!("{}/{}", self.server, self.chapter)
    }

    fn installed(&self, library: &Library) -> bool {
        let item = self.episode.as_deref().unwrap_or(&self.chapter);
        library
            .chapters
            .contains_key(&format!("{}/{item}", self.server))
    }
}

#[derive(Deserialize)]
struct RequestItem {
    #[serde(flatten)]
    target: Target,
    #[serde(default)]
    title: Option<String>,
}

#[derive(Clone, Copy, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum JobState {
    Queued,
    Downloading,
    Paused,
    Failed,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
pub(super) struct DownloadJob {
    #[serde(flatten)]
    target: Target,
    title: String,
    pub(super) state: JobState,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(default)]
    // Pending updates must survive a restart even when an older copy is present.
    update: bool,
}

fn requests(args: &Value) -> Result<Vec<RequestItem>> {
    let requests: Vec<RequestItem> = serde_json::from_value(args["items"].clone()).map_err(fail)?;
    if requests.len() > 20_000 || requests.iter().any(|request| !request.target.valid()) {
        return Err("offline_targets".into());
    }
    Ok(requests)
}

fn notify(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.eval("window.dispatchEvent(new Event('haneoka-offline-stories'))");
    }
}

impl Offline {
    fn edit_queue<T>(&self, edit: impl FnOnce(&mut Library) -> T) -> Result<T> {
        let mut library = self.library.lock().unwrap();
        let previous = library.queue.clone();
        let paused = library.queue_paused;
        let result = edit(&mut library);
        if previous != library.queue || paused != library.queue_paused {
            if let Err(error) = self.persist(&library) {
                library.queue = previous;
                library.queue_paused = paused;
                return Err(error);
            }
        }
        Ok(result)
    }

    fn append_jobs(&self, requests: Vec<RequestItem>, update: bool) -> Result<Value> {
        if requests.iter().any(|request| {
            Source::parse(&request.target.server).is_none() && request.target.episode.is_none()
        }) {
            return Err("story_episode".into());
        }
        self.edit_queue(|library| {
            let mut queued = 0;
            let mut already_saved = 0;
            let mut positions: BTreeMap<_, _> = library.queue.iter().enumerate()
                .map(|(index, job)| (job.target.clone(), index)).collect();
            let mut already_queued = 0;
            for request in requests {
                let target = request.target.normalized();
                if let Some(index) = positions.get(&target) {
                    let job = &mut library.queue[*index];
                    if job.state == JobState::Failed {
                        job.state = JobState::Queued;
                        job.error = None;
                        job.update |= update;
                        queued += 1;
                    } else {
                        already_queued += 1;
                    }
                    continue;
                }
                if !update && target.installed(library) {
                    already_saved += 1;
                    continue;
                }
                let title = request.title.filter(|value| !value.is_empty()).map_or_else(
                    || target.episode.as_ref().unwrap_or(&target.chapter).clone(),
                    |value| value.chars().take(300).collect(),
                );
                positions.insert(target.clone(), library.queue.len());
                library.queue.push(DownloadJob { title, target, state: JobState::Queued, error: None, update });
                queued += 1;
            }
            json!({"queued": queued, "alreadySaved": already_saved, "alreadyQueued": already_queued})
        })
    }

    fn queue_status(&self, args: &Value) -> Result<Value> {
        let requests = requests(args)?;
        let library = self.library.lock().unwrap();
        let jobs: BTreeMap<_, _> = library
            .queue
            .iter()
            .map(|job| (&job.target, job.state))
            .collect();
        let items = requests
            .into_iter()
            .map(|request| {
                let target = request.target.normalized();
                let state = jobs
                    .get(&target)
                    .map(|state| match state {
                        JobState::Queued if library.queue_paused => "paused",
                        JobState::Queued => "queued",
                        JobState::Downloading => "downloading",
                        JobState::Paused => "paused",
                        JobState::Failed => "failed",
                    })
                    .unwrap_or_else(|| {
                        if target.installed(&library) {
                            "saved"
                        } else {
                            "available"
                        }
                    });
                let mut row = serde_json::to_value(target).expect("offline target");
                row["state"] = json!(state);
                row
            })
            .collect::<Vec<_>>();
        Ok(json!({"items": items}))
    }

    async fn manage(&self, app: &AppHandle, args: &Value) -> Result<Value> {
        let requests = requests(args)?;
        match args["action"].as_str() {
            Some("update") => {
                let updates = {
                    let library = self.library.lock().unwrap();
                    let locale = app.state::<AppState>().preference("locale");
                    let locale = locale.as_str().unwrap_or("en");
                    requests
                        .into_iter()
                        .filter_map(|request| {
                            let chapter = library.chapters.get(&request.target.parent_key())?;
                            let mut target = request.target;
                            if target.server == "jp" || target.server == "intl" {
                                target.chapter = chapter.package.group_id.clone()?;
                                target.episode = Some(chapter.package.id.clone());
                            }
                            Some(RequestItem {
                                target,
                                title: Some(localized(&chapter.package.title, locale)),
                            })
                        })
                        .collect()
                };
                self.append_jobs(updates, true)?;
                Self::kick_queue(app);
            }
            Some("delete") => {
                // Serialize with the downloader so it cannot collect assets while a
                // related update is materializing a new snapshot.
                let _guard = self.action.try_lock().map_err(|_| "offline_busy")?;
                let mut library = self.library.lock().unwrap();
                let mut removed = Vec::new();
                for request in requests {
                    let key = request.target.parent_key();
                    if let Some(chapter) = library.chapters.remove(&key) {
                        removed.push((key, chapter));
                    }
                }
                let previous = library.queue.clone();
                for (_, chapter) in &removed {
                    library.queue.retain(|job| {
                        if job.target.server != chapter.server {
                            return true;
                        }
                        if job.target.chapter == chapter.package.id {
                            return false;
                        }
                        !job.target.episode.as_ref().is_some_and(|id| {
                            chapter
                                .package
                                .episodes
                                .iter()
                                .any(|episode| &episode.id == id)
                        })
                    });
                }
                if let Err(error) = self.persist(&library) {
                    library.chapters.extend(removed);
                    library.queue = previous;
                    return Err(error);
                }
                self.collect_objects(&library);
            }
            _ => return Err("offline_action".into()),
        }
        notify(app);
        Ok(self.view())
    }

    fn queue_control(&self, app: &AppHandle, args: &Value) -> Result<Value> {
        let targets: Vec<_> = if args["items"].is_null() {
            Vec::new()
        } else {
            requests(args)?
                .into_iter()
                .map(|request| request.target.normalized())
                .collect()
        };
        let action = args["action"].as_str().ok_or("offline_action")?;
        if !matches!(action, "pause" | "resume" | "retry" | "remove") {
            return Err("offline_action".into());
        }
        self.edit_queue(|library| {
            let mut stop = false;
            match action {
                "pause" => {
                    library.queue_paused = true;
                    stop = library
                        .queue
                        .iter()
                        .any(|job| job.state == JobState::Downloading);
                }
                "resume" | "retry" => {
                    library.queue_paused = false;
                    for job in &mut library.queue {
                        if job.state == JobState::Paused
                            || action == "retry"
                                && job.state == JobState::Failed
                                && (targets.is_empty() || targets.contains(&job.target))
                        {
                            job.state = JobState::Queued;
                            job.error = None;
                        }
                    }
                }
                "remove" => library.queue.retain(|job| {
                    if !targets.contains(&job.target) {
                        return true;
                    }
                    stop |= job.state == JobState::Downloading;
                    false
                }),
                _ => unreachable!(),
            }
            if stop {
                if let Some(status) = self.transfer.lock().unwrap().as_ref() {
                    status.paused.store(true, Ordering::Release);
                }
            }
        })?;
        notify(app);
        Self::kick_queue(app);
        Ok(self.view())
    }

    pub(super) async fn queue_command(
        &self,
        window: &WebviewWindow,
        method: &str,
        args: &Value,
    ) -> Option<Result<Value>> {
        let app = window.app_handle();
        match method {
            "offlineStatus" => Some(self.queue_status(args)),
            "offlineEnqueue" => {
                let result = requests(args).and_then(|requests| self.append_jobs(requests, false));
                if result.is_ok() {
                    notify(app);
                    Self::kick_queue(app);
                }
                Some(result)
            }
            "offlineManage" => Some(self.manage(app, args).await),
            "offlineQueue" => Some(self.queue_control(app, args)),
            _ => None,
        }
    }

    pub(crate) fn kick_queue(app: &AppHandle) {
        let state = app.state::<AppState>();
        let offline = &state.offline;
        let runnable = {
            let library = offline.library.lock().unwrap();
            !library.queue_paused
                && library
                    .queue
                    .iter()
                    .any(|job| job.state == JobState::Queued)
        };
        if !runnable || offline.queue_running.swap(true, Ordering::AcqRel) {
            return;
        }
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let state = app.state::<AppState>();
            let offline = &state.offline;
            let finished = offline.drain_queue(&app).await;
            *offline.transfer.lock().unwrap() = None;
            offline.queue_running.store(false, Ordering::Release);
            notify(&app);
            match finished {
                Ok(()) => Self::kick_queue(&app),
                Err(error) => log::warn!("Offline download queue: {error}"),
            }
        });
    }

    async fn drain_queue(&self, app: &AppHandle) -> Result<()> {
        loop {
            let _guard = self.action.lock().await;
            let status = Arc::new(Transfer::default());
            let job = self.edit_queue(|library| {
                if library.queue_paused {
                    return None;
                }
                let index = library
                    .queue
                    .iter()
                    .position(|job| job.state == JobState::Queued)?;
                if !library.queue[index].update && library.queue[index].target.installed(library) {
                    library.queue.remove(index);
                    return Some(None);
                }
                library.queue[index].state = JobState::Downloading;
                *self.transfer.lock().unwrap() = Some(status.clone());
                Some(Some(library.queue[index].clone()))
            })?;
            let Some(job) = job else {
                break;
            };
            let Some(job) = job else {
                notify(app);
                continue;
            };
            notify(app);
            let origin = crate::current_origin(app);
            let result = self.download_target(&origin, &job.target, &status).await;
            *self.transfer.lock().unwrap() = None;
            self.edit_queue(|library| {
                if let Some(index) = library
                    .queue
                    .iter()
                    .position(|entry| entry.target == job.target)
                {
                    match result {
                        Ok(()) => {
                            library.queue.remove(index);
                        }
                        Err(error)
                            if error == "paused" || status.paused.load(Ordering::Acquire) =>
                        {
                            library.queue[index].state = if library.queue_paused {
                                JobState::Paused
                            } else {
                                JobState::Queued
                            };
                        }
                        Err(error) => {
                            library.queue[index].state = JobState::Failed;
                            library.queue[index].error = Some(error);
                        }
                    }
                }
            })?;
            notify(app);
        }
        Ok(())
    }

    async fn download_target(
        &self,
        origin: &str,
        target: &Target,
        status: &Transfer,
    ) -> Result<()> {
        let source = Source::parse(&target.server);
        if !self.player_present() {
            self.install_player(origin, status).await?;
            if !self.player_present() {
                return Err("player_missing".into());
            }
        }
        if status.paused.load(Ordering::Acquire) {
            return Err("paused".into());
        }
        if let Some(source) = source {
            self.install_portable_story(origin, &target.server, source, &target.chapter, status)
                .await
        } else {
            let episode = target.episode.as_deref().ok_or("story_episode")?;
            self.install_episode(origin, &target.server, &target.chapter, episode, status)
                .await
        }
    }
}
