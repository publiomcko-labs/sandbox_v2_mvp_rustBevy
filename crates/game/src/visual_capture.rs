//! Optional diagnostic render screenshots; B8 captures a timed 1080p
//! sequence to inspect temporal LOD replacement rather than one still frame.
use bevy::{
    prelude::*,
    render::view::screenshot::{Screenshot, save_to_disk},
};
use sandbox_gpu_terrain::b2::B2HeadlessTarget;
use std::path::PathBuf;

#[derive(Resource)]
struct VisualCaptureState {
    path: PathBuf,
    times: Vec<f32>,
    next: usize,
    requested_at: Option<f32>,
    pending_path: Option<PathBuf>,
}

pub fn configure(app:&mut App) {
    let Ok(path)=std::env::var("SANDBOX_B2_CAPTURE_PATH") else{return;};
    let capture_after_secs=std::env::var("SANDBOX_B3_CAPTURE_AFTER_SECONDS")
        .ok().and_then(|s|s.parse::<f32>().ok())
        .filter(|n|n.is_finite()&&*n>=1.0&&*n<=90.0).unwrap_or(7.0);
    let sequence=std::env::var("SANDBOX_B8_CAPTURE_SEQUENCE").as_deref()==Ok("1");
    // A real time-series records intermediate LOD updates as the camera moves.
    // Never interpret it alone as proof that no sub-frame flicker exists.
    let times=if sequence {
        vec![12.0,16.0,20.0,24.0,28.0,32.0,36.0,40.0,44.0]
    }else{vec![capture_after_secs]};
    app.insert_resource(VisualCaptureState{
        path:PathBuf::from(path),times,next:0,requested_at:None,pending_path:None,
    }).add_systems(Update,capture_frame);
}

fn capture_frame(
    mut commands:Commands,
    time:Res<Time>,
    mut state:ResMut<VisualCaptureState>,
    mut exit:MessageWriter<AppExit>,
    headless_target:Option<Res<B2HeadlessTarget>>,
) {
    let now=time.elapsed_secs();
    if state.next>=state.times.len(){return;}
    if let (Some(start),Some(pending))=(state.requested_at,state.pending_path.clone()) {
        if now-start>=0.2 &&
            std::fs::metadata(&pending).is_ok_and(|m|m.len()>2000)
        {
            info!(sequence_index=state.next, path=%pending.display(),
                  "B2 visual CI: screenshot captured at");
            state.next+=1;
            state.pending_path=None;
            state.requested_at=None;
            if state.next>=state.times.len(){exit.write(AppExit::Success);}
        } else if now-start>25.0 {
            error!(sequence_index=state.next,
                  "B8 screenshot did not complete within capture deadline");
            std::process::exit(3);
        }
        return;
    }
    if now<state.times[state.next] {return;}
    let path=if state.times.len()==1 {state.path.clone()} else {
        let base=state.path.file_stem().and_then(|s|s.to_str()).unwrap_or("capture");
        state.path.with_file_name(format!("{base}-{:02}.png",state.next+1))
    };
    let capture=match headless_target{
        Some(target)=>Screenshot::image(target.0.clone()),
        None=>Screenshot::primary_window(),
    };
    info!(sequence_index=state.next, at_s=now, path=%path.display(),
          "B8 visual CI: requesting screenshot");
    commands.spawn(capture).observe(save_to_disk(path.clone()));
    state.requested_at=Some(now);
    state.pending_path=Some(path);
}
