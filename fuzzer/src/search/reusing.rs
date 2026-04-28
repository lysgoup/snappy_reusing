use crate::{fuzz_type::FuzzType, mut_input::MutInput};
use super::SearchHandler;
use rand::prelude::*;

#[derive(Copy, Clone)]
pub enum ReuseTarget {
    Offsets,
    OffsetsOpt,
    MergedOffsets,
}

pub struct ReusingFuzz<'a> {
    handler: SearchHandler<'a>,
}

impl<'a> ReusingFuzz<'a> {
    pub fn new(mut handler: SearchHandler<'a>) -> Self {
        handler.executor.local_stats.fuzz_type = FuzzType::ReusingFuzz;
        Self { handler }
    }

    pub fn run<R: Rng + ?Sized>(&mut self, rng: &mut R, target: ReuseTarget) {
        let reuse_offsets = match target {
            ReuseTarget::Offsets => self.handler.cond.reuse_offsets.clone(),
            ReuseTarget::OffsetsOpt => self.handler.cond.reuse_offsets_opt.clone(),
            ReuseTarget::MergedOffsets => self.handler.cond.reuse_merged_offsets.clone(),
        };

        if reuse_offsets.is_empty() {
            return;
        }

        let sizes: Vec<usize> = reuse_offsets
            .iter()
            .map(|seg| (seg.end - seg.begin) as usize)
            .collect();

        let mut input = MutInput::from(&reuse_offsets, &self.handler.buf);

        // Sequential reusing
        let mut cursor = match target {
            ReuseTarget::Offsets => self.handler.cond.reuse_cursor,
            ReuseTarget::OffsetsOpt => self.handler.cond.reuse_cursor_opt,
            ReuseTarget::MergedOffsets => self.handler.cond.reuse_cursor_merged,
        };
        loop {
            if self.handler.is_stopped_or_skip() {
                break;
            }
            match self.handler.executor.get_reuse_at(&sizes, cursor) {
                Some(bytes) => {
                    input.assign(&bytes);
                    self.handler.execute_input_at_ignore_skip(&input, &reuse_offsets);
                    cursor += 1;
                },
                None => break,
            }
        }
        match target {
            ReuseTarget::Offsets => self.handler.cond.reuse_cursor = cursor,
            ReuseTarget::OffsetsOpt => self.handler.cond.reuse_cursor_opt = cursor,
            ReuseTarget::MergedOffsets => self.handler.cond.reuse_cursor_merged = cursor,
        }

        // Cross-segment reusing: only for Offsets/OffsetsOpt with multiple segments
        if matches!(target, ReuseTarget::Offsets | ReuseTarget::OffsetsOpt)
            && reuse_offsets.len() > 1
        {
            for _ in 0..50 {
                if self.handler.is_stopped_or_skip() {
                    break;
                }
                let mut combined = Vec::new();
                let mut any_empty = false;
                for seg in &reuse_offsets {
                    let seg_size = [(seg.end - seg.begin) as usize];
                    match self.handler.executor.sample_reuse(&seg_size, rng) {
                        Some(bytes) => combined.extend_from_slice(&bytes),
                        None => { any_empty = true; break; }
                    }
                }
                if any_empty {
                    break;
                }
                input.assign(&combined);
                self.handler.execute_input_at_ignore_skip(&input, &reuse_offsets);
            }
        }
    }
}
