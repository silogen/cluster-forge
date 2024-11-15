use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use serde::{Deserialize, Serialize};
use serde_yaml;
use log::{debug, error, info};

use crate::utils::{template_helm, Config};

#[derive(Debug, Serialize, Deserialize)]
struct K8sObject {
    kind: String,
    api_version: String,
    metadata: Metadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct Metadata {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    namespace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    labels: Option<HashMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    annotations: Option<HashMap<String, String>>,
}

#[derive(Debug)]
struct TargetTool {
    tools: Vec<String>,
}


pub fn smelt(configs: &Vec<Config>) {
    info!("Starting up the menu...");

    let mut target_tool = TargetTool { tools: Vec::new() };
    let mut names = vec!["all".to_string()];

    for config in configs {
        names.push(config.name.clone());
    }

    target_tool.tools = names.clone();

    if target_tool.tools.contains(&"all".to_string()) {
        for config in configs {
            target_tool.tools.push(config.name.clone());
        }
        target_tool.tools.retain(|tool| tool != "all");
    }

    let config_map: HashMap<String, Config> = configs.iter().cloned().map(|config| (config.name.clone(), config)).collect();

    for tool in &target_tool.tools {
        if let Some(config) = config_map.get(tool) {
            debug!("Running setup for {}", config.name);
            prepare_tool(config);
        } else {
            error!("Config for tool {} not found", tool);
        }
    }

    print_summary(&target_tool);
}

fn prepare_tool(config: &Config) {
    let namespace_template = r#"apiVersion: v1
kind: Namespace
metadata:
  name: {{ .NamespaceName }}"#;

    let working_dir = format!("working/pre/{}", config.name);

    if let Ok(entries) = fs::read_dir(&working_dir) {
        for entry in entries {
            if let Ok(entry) = entry {
                let path = entry.path();
                if path.is_file() && !path.file_name().unwrap().to_str().unwrap().contains("ExternalSecret") {
                    if let Err(e) = fs::remove_file(&path) {
                        error!("Error deleting file {}: {}", path.display(), e);
                    }
                }
            }
        }
    }

    if let Err(e) = template_helm(config) {
        error!("Error templating helm for {}: {}", config.name, e);
        return;
    }

    if let Err(e) = split_yaml(config) {
        error!("Error splitting YAML for {}: {}", config.name, e);
        return;
    }

    let namespace_object = fs::read_dir(format!("working/{}", config.name))
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .any(|entry| entry.file_name().to_string_lossy().contains("Namespace"))
        })
        .unwrap_or(false);

    if !namespace_object && config.source_file.is_none() {
        if let Some(namespace) = &config.namespace {
            let namespace_data = namespace_template.replace("{{ .NamespaceName }}", namespace);

            let namespace_path = format!("working/{}/Namespace_{}.yaml", config.name, config.name);

            fs::write(&namespace_path, namespace_data)
                .expect("Failed to write namespace YAML file");
        } else {
            error!("Namespace is missing for config: {}", config.name);
        }
    }
}

fn split_yaml(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(filename) = &config.filename {
        let data = fs::read_to_string(filename)?;
        let documents: Vec<&str> = data.split("---").collect();

        for doc in documents {
            let cleaned = clean(doc.as_bytes())?;
            let mut object: K8sObject = serde_yaml::from_slice(&cleaned)?;

            if object.metadata.namespace.is_none() {
                if let Some(namespace) = &config.namespace {
                    object.metadata.namespace = Some(namespace.clone());
                } else {
                    error!("Namespace is missing for config: {}", config.name);
                }
            }

            let filename = format!("working/{}/{}_{}.yaml", config.name, object.kind, object.metadata.name);
            let updated_yaml = serde_yaml::to_string(&object)?;

            fs::write(filename, updated_yaml)?;
        }
    } else {
        error!("Filename is missing for config: {}", config.name);
    }

    Ok(())
}


fn clean(input: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut output = Vec::new();
    let reader = BufReader::new(input);

    for line in reader.lines() {
        let line = line?;
        if line.contains("---") || line.starts_with('#') {
            continue;
        }
        output.extend_from_slice(line.as_bytes());
        output.push(b'\n');
    }

    Ok(output)
}

fn print_summary(toolbox: &TargetTool) {
    println!("Cluster Forge\n\nCompleted: {}.", toolbox.tools.join(", "));
}



