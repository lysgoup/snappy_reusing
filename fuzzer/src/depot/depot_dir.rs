use angora_common::defs;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub struct DepotDir {
    pub inputs_dir: PathBuf,
    pub hangs_dir: PathBuf,
    pub crashes_dir: PathBuf,
    pub seeds_dir: PathBuf,
    pub signal_dir: PathBuf,
}

impl DepotDir {
    pub fn new(seeds_dir: PathBuf, out_dir: &Path) -> Self {
        let inputs_dir = out_dir.join(defs::INPUTS_DIR);
        let hangs_dir = out_dir.join(defs::HANGS_DIR);
        let crashes_dir = out_dir.join(defs::CRASHES_DIR);
        let signal_dir = inputs_dir.join(defs::SIGNAL_DIR);

        fs::create_dir(&crashes_dir).unwrap();
        fs::create_dir(&hangs_dir).unwrap();
        fs::create_dir(&inputs_dir).unwrap();
        fs::create_dir(&signal_dir).unwrap();


        Self {
            inputs_dir,
            hangs_dir,
            crashes_dir,
            seeds_dir,
            signal_dir,
        }
    }

    pub fn write_signal(&self, name: &str, content: &str) {
        let path = self.signal_dir.join(name);
        match fs::File::create(&path).and_then(|mut f| f.write_all(content.as_bytes())) {
            Ok(_) => {},
            Err(e) => warn!("Failed to write signal file {:?}: {:?}", path, e),
        }
    }
}
