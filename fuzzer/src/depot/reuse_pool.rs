use crate::cond_stmt::CondStmt;
use angora_common::tag::TagSeg;
use rand::prelude::*;
use std::{collections::HashMap, sync::Mutex};

pub struct ReuseEntry {
    pub cmpid: u32,
    pub context: u32,
    pub condition: u32,
    pub offsets: Vec<TagSeg>,
    pub bytes: Vec<u8>,
}

pub struct ReusePool {
    // Key: raw sizes of each tainted segment (e.g., [4, 2] for two segments of 4 and 2 bytes)
    // Value: list of entries captured from inputs that increased coverage
    pool: Mutex<HashMap<Vec<usize>, Vec<ReuseEntry>>>,
}

impl ReusePool {
    pub fn new() -> Self {
        Self {
            pool: Mutex::new(HashMap::new()),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.pool.lock().unwrap().is_empty()
    }

    pub fn add_from_conds(&self, cond_stmts: &[CondStmt], buf: &[u8]) {
        let mut pool = self.pool.lock().unwrap();
        for cond in cond_stmts {
            // For reuse_offsets and reuse_offsets_opt: store combined + each segment individually
            for offsets in [&cond.reuse_offsets, &cond.reuse_offsets_opt] {
                if offsets.is_empty() {
                    continue;
                }
                Self::insert_entry(&mut pool, offsets, buf, cond);
                if offsets.len() > 1 {
                    for seg in offsets.iter() {
                        Self::insert_entry(&mut pool, std::slice::from_ref(seg), buf, cond);
                    }
                }
            }
            // For reuse_merged_offsets: store combined only
            if !cond.reuse_merged_offsets.is_empty() {
                Self::insert_entry(&mut pool, &cond.reuse_merged_offsets, buf, cond);
            }
        }
    }

    fn insert_entry(
        pool: &mut HashMap<Vec<usize>, Vec<ReuseEntry>>,
        offsets: &[TagSeg],
        buf: &[u8],
        cond: &CondStmt,
    ) {
        let all_valid = offsets
            .iter()
            .all(|seg| seg.begin < seg.end && seg.end as usize <= buf.len());
        if !all_valid {
            return;
        }

        let key: Vec<usize> = offsets
            .iter()
            .map(|seg| (seg.end - seg.begin) as usize)
            .collect();

        let bytes: Vec<u8> = offsets
            .iter()
            .flat_map(|seg| &buf[seg.begin as usize..seg.end as usize])
            .copied()
            .collect();

        let entries = pool.entry(key).or_insert_with(Vec::new);
        if entries.iter().any(|e| e.bytes == bytes) {
            return;
        }
        entries.push(ReuseEntry {
            cmpid: cond.base.cmpid,
            context: cond.base.context,
            condition: cond.base.condition,
            offsets: offsets.to_vec(),
            bytes,
        });
    }

    pub fn dump(&self, path: &std::path::Path) {
        use std::io::Write;

        let pool = self.pool.lock().unwrap();
        let total: usize = pool.values().map(|v| v.len()).sum();

        let mut f = match std::fs::File::create(path) {
            Ok(f) => f,
            Err(e) => {
                log::error!("Could not create reuse_pool.txt: {:?}", e);
                return;
            },
        };

        writeln!(f, "Total entries: {}", total).ok();

        for (pattern, entries) in pool.iter() {
            writeln!(f, "\nPattern {:?} ({} entries):", pattern, entries.len()).ok();
            for (i, entry) in entries.iter().enumerate() {
                writeln!(f, "  Entry {}:", i).ok();
                writeln!(f, "    cmpid: {}", entry.cmpid).ok();
                writeln!(f, "    context: {}", entry.context).ok();
                writeln!(f, "    condition: {}", entry.condition).ok();
                let offsets_str: Vec<String> = entry
                    .offsets
                    .iter()
                    .map(|seg| format!("(begin={}, end={})", seg.begin, seg.end))
                    .collect();
                writeln!(f, "    offsets: [{}]", offsets_str.join(", ")).ok();
                let bytes_str: Vec<String> =
                    entry.bytes.iter().map(|b| format!("{:02x}", b)).collect();
                writeln!(f, "    bytes: [{}]", bytes_str.join(" ")).ok();
            }
        }

        log::warn!("Reuse pool written to {:?} ({} entries)", path, total);
    }

    /// Get the entry at a specific index for the given size pattern.
    /// Returns None if no entry exists at that index.
    pub fn get_at(&self, sizes: &[usize], index: usize) -> Option<Vec<u8>> {
        let pool = self.pool.lock().unwrap();
        let entries = pool.get(sizes)?;
        entries.get(index).map(|e| e.bytes.clone())
    }

    /// Sample a random byte sequence matching `sizes` from the pool.
    /// Returns None if no entry with that size pattern exists.
    pub fn sample<R: Rng + ?Sized>(&self, sizes: &[usize], rng: &mut R) -> Option<Vec<u8>> {
        let pool = self.pool.lock().unwrap();
        let entries = pool.get(sizes)?;
        if entries.is_empty() {
            return None;
        }
        let idx = rng.gen_range(0..entries.len());
        Some(entries[idx].bytes.clone())
    }
}
