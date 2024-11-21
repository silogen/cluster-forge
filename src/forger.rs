use log::{error, info};
use std::{
    fs,
    io,
    path::Path,
    process::Command,
    thread,
    time::Duration,
    error::Error,

};
use dialoguer::Select;
use kube::config::{Config, Kubeconfig, KubeConfigOptions};
use dirs_next;

pub fn forge() {
    info!("Starting Cluster Forge...");

    let base_path = "./packages";
    let kubeconfig_path = dirs_next::home_dir()
        .expect("Failed to find home directory")
        .join(".kube/config");

    match get_kube_config(&kubeconfig_path) {
        Ok(_) => info!("Kubernetes client configured successfully"),
        Err(e) => error!("Failed to configure Kubernetes client: {:?}", e),
    }

    let stacks = get_stacks(base_path).expect("Failed to retrieve stacks");
    let selected_stack = get_user_selection(&stacks);

    run_stack_logic(&format!("{}/{}", base_path, selected_stack));
}

fn get_kube_config(kubeconfig_path: &Path) -> Result<Config, Box<dyn Error>> {
    let runtime = tokio::runtime::Runtime::new()?; // Create a runtime

    if kubeconfig_path.exists() {
        info!("Using kubeconfig file at: {}", kubeconfig_path.display());

        let kubeconfig = Kubeconfig::read_from(kubeconfig_path)?;
        let contexts = kubeconfig
            .contexts
            .iter()
            .map(|ctx| ctx.name.clone())
            .collect::<Vec<_>>();

        let selected_context = get_user_context_selection(&contexts);

        let options = KubeConfigOptions {
            context: Some(selected_context),
            cluster: None,
            user: None,
        };

        let config = runtime.block_on(Config::from_kubeconfig(&options))?;
        Ok(config)
    } else {
        info!("Kubeconfig file not found, falling back to in-cluster configuration");
        let config = runtime.block_on(Config::infer())?;
        Ok(config)
    }
}



fn get_user_context_selection(contexts: &[String]) -> String {
    if contexts.is_empty() {
        panic!("No contexts available in kubeconfig");
    }

    let selected = Select::new()
        .with_prompt("Select a Kubernetes context")
        .items(contexts)
        .default(0)
        .interact()
        .expect("Failed to get user selection");

    contexts[selected].clone()
}

fn get_stacks(base_dir: &str) -> io::Result<Vec<String>> {
    let mut stacks = Vec::new();

    for entry in fs::read_dir(base_dir)? {
        let entry = entry?;
        if entry.path().is_dir() {
            if let Some(name) = entry.file_name().to_str() {
                stacks.push(name.to_string());
            }
        }
    }

    Ok(stacks)
}

fn get_user_selection(stacks: &[String]) -> String {
    let selected = Select::new()
        .with_prompt("Select a stack to deploy")
        .items(stacks)
        .default(0)
        .interact()
        .expect("Failed to get user selection");

    stacks[selected].clone()
}

fn run_stack_logic(stack_path: &str) {
    info!("Deploying stack from: {}", stack_path);

    run_command(&format!("kubectl apply -f {}/crossplane_base.yaml", stack_path));
    run_command("kubectl wait --for=condition=available --timeout=600s deployments --all --all-namespaces");

    apply_matching_files(stack_path, "crd-*.yaml", true);
    apply_matching_files(stack_path, "cm-*.yaml", false);

    run_command(&format!("kubectl apply -f {}/crossplane.yaml", stack_path));
    thread::sleep(Duration::from_secs(20));
    run_command(&format!("kubectl apply -f {}/function-templates.yaml", stack_path));
    run_command(&format!("kubectl apply -f {}/crossplane_provider.yaml", stack_path));
    run_command(&format!("kubectl apply -f {}/composition.yaml", stack_path));

    run_command("kubectl delete pods --all -n crossplane-system");
    run_command("kubectl wait --for=condition=Ready --timeout=600s pods --all --all-namespaces");

    run_command(&format!("kubectl apply -f {}/claim.yaml", stack_path));
    install_helm_chart("komodorio", "https://helm-charts.komodor.io", "komoplane", "komodorio/komoplane");
    run_command("kubectl wait --for=condition=Ready --timeout=600s pods --all -n default");

    info!("Deployment complete!");
}

fn apply_matching_files(dir: &str, pattern: &str, server_side: bool) {
    let glob_pattern = format!("{}/{}", dir, pattern);

    match glob::glob(&glob_pattern) {
        Ok(paths) => {
            for path in paths {
                if let Ok(path) = path {
                    let mut command = format!("kubectl apply -f {}", path.display());
                    if server_side {
                        command.push_str(" --server-side");
                    }
                    run_command(&command);
                }
            }
        }
        Err(e) => error!("Failed to find files matching pattern {}: {:?}", pattern, e),
    }
}

fn install_helm_chart(repo_name: &str, repo_url: &str, release_name: &str, chart_name: &str) {
    let command = format!(
        "helm repo add {} {} && helm repo update && helm upgrade --install {} {}",
        repo_name, repo_url, release_name, chart_name
    );
    run_command(&command);
}

fn run_command(command: &str) {
    match Command::new("sh").arg("-c").arg(command).output() {
        Ok(output) => {
            if !output.status.success() {
                error!("Command failed: {}", String::from_utf8_lossy(&output.stderr));
            } else {
                info!("{}", String::from_utf8_lossy(&output.stdout));
            }
        }
        Err(e) => error!("Failed to execute command {}: {:?}", command, e),
    }
}

