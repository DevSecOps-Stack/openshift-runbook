# ACM (Advanced Cluster Management) - AWS Security Group & NACL Rules

This table provides the recommended **Security Group (SG) inbound rules** and **bidirectional Network ACL (NACL) rules** for ACM cluster connectivity.  
Format matches the AWS Console UI tables.  
**Note:** For NACLs, every inbound rule must have a matching outbound rule.

---

## Security Group (SG) - Inbound Rules

| Type           | Protocol | Port Range      | Source             |
|----------------|----------|-----------------|--------------------|
| Custom UDP     | UDP      | 4800            | 10.191.152.0/21    |
| Custom UDP     | UDP      | 4789            | 10.191.152.0/21    |
| Custom TCP     | TCP      | 8080            | 10.191.152.0/21    |
| Custom UDP     | UDP      | 4500            | 10.191.152.0/21    |
| Custom UDP     | UDP      | 500             | 10.191.152.0/21    |
| Custom Protocol| 50 (ESP) | N/A             | 10.191.152.0/21    |
| Custom TCP     | TCP      | 53              | 10.191.152.0/21    |
| Custom UDP     | UDP      | 53              | 10.191.152.0/21    |
| Custom UDP     | UDP      | 4490            | 10.191.152.0/21    |

---

## Network ACL (NACL) - Inbound Rules

| Rule # | Type           | Protocol | Port Range | Source             | Allow/Deny |
|--------|----------------|----------|------------|--------------------|------------|
| 100    | Custom UDP     | UDP      | 4800       | 10.191.152.0/21    | Allow      |
| 101    | Custom UDP     | UDP      | 4789       | 10.191.152.0/21    | Allow      |
| 102    | Custom TCP     | TCP      | 8080       | 10.191.152.0/21    | Allow      |
| 103    | Custom UDP     | UDP      | 4500       | 10.191.152.0/21    | Allow      |
| 104    | Custom UDP     | UDP      | 500        | 10.191.152.0/21    | Allow      |
| 105    | Custom Protocol| 50 (ESP) | N/A        | 10.191.152.0/21    | Allow      |
| 106    | Custom TCP     | TCP      | 53         | 10.191.152.0/21    | Allow      |
| 107    | Custom UDP     | UDP      | 53         | 10.191.152.0/21    | Allow      |
| 108    | Custom UDP     | UDP      | 4490       | 10.191.152.0/21    | Allow      |

---

## Network ACL (NACL) - **Outbound Rules**

| Rule # | Type           | Protocol | Port Range | Destination        | Allow/Deny |
|--------|----------------|----------|------------|--------------------|------------|
| 100    | Custom UDP     | UDP      | 4800       | 10.191.152.0/21    | Allow      |
| 101    | Custom UDP     | UDP      | 4789       | 10.191.152.0/21    | Allow      |
| 102    | Custom TCP     | TCP      | 8080       | 10.191.152.0/21    | Allow      |
| 103    | Custom UDP     | UDP      | 4500       | 10.191.152.0/21    | Allow      |
| 104    | Custom UDP     | UDP      | 500        | 10.191.152.0/21    | Allow      |
| 105    | Custom Protocol| 50 (ESP) | N/A        | 10.191.152.0/21    | Allow      |
| 106    | Custom TCP     | TCP      | 53         | 10.191.152.0/21    | Allow      |
| 107    | Custom UDP     | UDP      | 53         | 10.191.152.0/21    | Allow      |
| 108    | Custom UDP     | UDP      | 4490       | 10.191.152.0/21    | Allow      |

---

> **Note:**  
> - Security groups are stateful: replies are automatically allowed.
> - NACLs are stateless: if you allow inbound, you *must* also allow outbound for the same ports/protocols.
> - For best practice, number your rules identically inbound/outbound for clarity.
> - Adjust the CIDR (`10.191.152.0/21`) to match your actual cluster network where required.
