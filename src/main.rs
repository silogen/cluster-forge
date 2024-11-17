use clap::{Command, Arg};
use log::{debug, error, info};
use std::process;

mod utils;
mod smelter;
mod caster;
mod forger;

use crate::utils::setup_logging; 

fn print_usage() {
    println!("Usage:\n\
    To setup components, use:\n\
    cluster-forge --smelt\n\
\n\
    Or to combine components for deployment, use:\n\
    cluster-forge --cast\n\
\n\
    Or, to deploy to a specific cluster, use:\n\
    cluster-forge --forge --kubeconfig <KUBECONFIG>");
}
#[tokio::main]
async fn main() {
    if let Err(e) = setup_logging() {
        eprintln!("Failed to initialize logging: {}", e);
        std::process::exit(1);
    };


    let matches = Command::new("Cluster Forge")
        .version("1.0")
        .about("Cluster management and deployment tool")
        .arg(
            Arg::new("smelt")
                .long("smelt")
                .short('s')
                .help("Run smelt")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("cast")
                .long("cast")
                .short('c')
                .help("Run cast")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("forge")
                .long("forge")
                .short('f')
                .help("Run forge")
                .action(clap::ArgAction::SetTrue),
        )
        .get_matches();

    let selected_mode = if matches.contains_id("smelt") {
        "smelt"
    } else if matches.contains_id("cast") {
        "cast"
    } else if matches.contains_id("forge") {
        "forge"
    } else {
        print_usage();
        error!("No mode selected");
        process::exit(1);
    };

    info!("starting up...");


    let configs: Vec<utils::Config> = match utils::load_config("input/config.yaml") {
        Ok(configs) => configs,
        Err(e) => {
            error!("Failed to read config: {}", e);
            process::exit(1);
        }
    };

    for config in &configs {
        debug!("Read config for: {}", config.name);
    }

    match selected_mode {
        "smelt" => {
            println!("Smelting");
            smelter::smelt(&configs).await;
        }
        "cast" => {
            println!("Casting");
            caster::cast(&configs);
        }
        "forge" => {
            println!("Forging");
            forger::forge().await;
        }
        _ => unreachable!(),
    }
}